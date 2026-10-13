// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ChartHealthHook} from "../src/ChartHealthHook.sol";

contract TestChartHealthHook is Test, Deployers {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    ChartHealthHook hook;
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint64 constant CANDLE_PERIOD = 1 hours;
    int24 constant MIN_RANGE_TICKS = 100;

    uint256 constant TOP_BLASTER = 0;
    uint256 constant SUPPORTER = 1;
    uint256 constant EXTRACTOR = 2;
    uint256 constant PAPER_HANDS = 3;

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));
        token.mint(address(this), 10_000 ether);

        // Deploy hook to an address with the AFTER_INITIALIZE and AFTER_SWAP flags set
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("ChartHealthHook.sol", abi.encode(manager, CANDLE_PERIOD, MIN_RANGE_TICKS), address(flags));
        hook = ChartHealthHook(address(flags));

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        (key,) = initPool(ethCurrency, tokenCurrency, hook, 3000, SQRT_PRICE_1_1);
        poolId = key.toId();

        // Deep, wide liquidity so swaps move the price by a few hundred ticks
        uint256 ethToAdd = 100 ether;
        uint128 liquidityDelta =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(6000), ethToAdd);
        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -6000,
                tickUpper: 6000,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Buy TOKEN with `ethIn` ETH on behalf of `user`. Returns ETH spent.
    function buy(address user, uint256 ethIn) internal returns (uint256) {
        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user)
        );
        return ethIn;
    }

    /// @dev Sell `tokenIn` TOKEN for ETH on behalf of `user`. Returns ETH received.
    function sell(address user, uint256 tokenIn) internal returns (uint256 ethOut) {
        uint256 before = address(this).balance;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user)
        );
        ethOut = address(this).balance - before;
    }

    function badges(address user) internal view returns (uint256[4] memory b) {
        for (uint256 i; i < 4; i++) {
            b[i] = hook.balanceOf(user, i);
        }
    }

    /// @dev Pump the chart: a big neutral buy from a flat range puts the price at the top.
    function pump() internal {
        buy(bob, 10 ether);
        assertEq(uint256(hook.currentZone(poolId)), uint256(ChartHealthHook.Zone.TOP));
    }

    /// @dev Pump then dump: price ends at the bottom of the range.
    function pumpAndDump() internal {
        pump();
        sell(bob, 25 ether);
        assertEq(uint256(hook.currentZone(poolId)), uint256(ChartHealthHook.Zone.BOTTOM));
    }

    // ---------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------

    function test_flatChart_noBadges() public {
        // Freshly initialized pool has no range yet, so the first swap is neutral
        buy(alice, 1 ether);
        uint256[4] memory b = badges(alice);
        for (uint256 i; i < 4; i++) {
            assertEq(b[i], 0);
        }
        assertEq(hook.chartScore(alice), 0);
    }

    function test_rangeTracksPriceAction() public {
        pump();
        (int24 low, int24 high) = hook.getRange(poolId);
        assertEq(low, 0);
        assertGt(high, MIN_RANGE_TICKS);
    }

    function test_buyAtTop_isTopBlaster() public {
        pump();
        buy(alice, 1 ether);

        assertEq(hook.balanceOf(alice, TOP_BLASTER), 1 ether);
        assertEq(hook.chartScore(alice), 2 ether); // +2x weight
    }

    function test_sellAtTop_isExtractor() public {
        pump();
        uint256 ethOut = sell(alice, 1 ether);

        assertGt(ethOut, 0);
        assertEq(hook.balanceOf(alice, EXTRACTOR), ethOut);
        assertEq(hook.chartScore(alice), -int256(ethOut)); // -1x weight
    }

    function test_buyAtBottom_isSupporter() public {
        pumpAndDump();
        buy(alice, 1 ether);

        assertEq(hook.balanceOf(alice, SUPPORTER), 1 ether);
        assertEq(hook.chartScore(alice), 1 ether); // +1x weight
    }

    function test_sellAtBottom_isPaperHands() public {
        pumpAndDump();
        uint256 ethOut = sell(alice, 1 ether);

        assertEq(hook.balanceOf(alice, PAPER_HANDS), ethOut);
        assertEq(hook.chartScore(alice), -2 * int256(ethOut)); // -2x weight
    }

    function test_dumperFromTop_isExtractor() public {
        // Bob pumps (neutral, flat chart), then dumps starting from the top -> extractor
        pump();
        uint256 ethOut = sell(bob, 25 ether);
        assertEq(hook.balanceOf(bob, EXTRACTOR), ethOut);
        assertEq(hook.balanceOf(bob, TOP_BLASTER), 0);
    }

    function test_noHookData_noBadges() public {
        pump();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        assertEq(hook.balanceOf(address(this), TOP_BLASTER), 0);
    }

    function test_rangeResetsAfterQuietPeriod() public {
        pump();
        // Two full candles with no trading: the old pump falls out of the window,
        // the chart is flat again and swaps are neutral
        vm.warp(block.timestamp + 2 * CANDLE_PERIOD);
        buy(alice, 1 ether);

        assertEq(hook.balanceOf(alice, TOP_BLASTER), 0);
        assertEq(hook.chartScore(alice), 0);
    }

    function test_rangeSurvivesOneCandle() public {
        pump();
        // Next candle: the previous candle's pump is still in the window
        vm.warp(block.timestamp + CANDLE_PERIOD);
        buy(alice, 1 ether);
        assertEq(hook.balanceOf(alice, TOP_BLASTER), 1 ether);
    }

    function test_badgesAreSoulbound() public {
        pump();
        buy(alice, 1 ether);

        vm.startPrank(alice);
        vm.expectRevert(ChartHealthHook.Soulbound.selector);
        hook.safeTransferFrom(alice, bob, TOP_BLASTER, 1, "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectRevert(ChartHealthHook.Soulbound.selector);
        hook.safeBatchTransferFrom(alice, bob, ids, amounts, "");

        vm.expectRevert(ChartHealthHook.Soulbound.selector);
        hook.setApprovalForAll(bob, true);
        vm.stopPrank();

        assertEq(hook.balanceOf(alice, TOP_BLASTER), 1 ether);
    }

    function test_scoreAccumulatesAcrossBadges() public {
        pump();
        buy(alice, 1 ether); // top blaster: +2
        uint256 extracted = sell(alice, 0.5 ether); // still near top: extractor -1

        assertEq(hook.balanceOf(alice, TOP_BLASTER), 1 ether);
        assertEq(hook.balanceOf(alice, EXTRACTOR), extracted);
        assertEq(hook.chartScore(alice), 2 * 1 ether - int256(extracted));
    }
}
