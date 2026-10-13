// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
import {Plan, Planner} from "v4-periphery/test/shared/Planner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {ChartHealthHook} from "../src/ChartHealthHook.sol";

contract ChartHealthHookTest is Test, Deployers {
    ChartHealthHook hook;
    MockV4Router trustedRouter;
    Currency eth = Currency.wrap(address(0));
    Currency token;

    address alice = makeAddr("alice");
    uint64 constant PERIOD = 1 hours;

    function setUp() public {
        deployFreshManagerAndRouters();
        trustedRouter = new MockV4Router(manager);

        MockERC20 t = new MockERC20("Test Token", "TEST", 18);
        token = Currency.wrap(address(t));
        t.mint(address(this), 10_000 ether);
        t.mint(alice, 1_000 ether);
        t.approve(address(swapRouter), type(uint256).max);
        t.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.prank(alice);
        t.approve(address(trustedRouter), type(uint256).max);
        vm.deal(alice, 100 ether);

        address[] memory routers = new address[](1);
        routers[0] = address(trustedRouter);
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("ChartHealthHook.sol", abi.encode(manager, defaultConfig(), routers), address(flags));
        hook = ChartHealthHook(address(flags));

        (key,) = initPool(eth, token, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(6000), 100 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            key, ModifyLiquidityParams(-6000, 6000, int256(uint256(liquidity)), 0), ZERO_BYTES
        );
    }

    function defaultConfig() internal pure returns (ChartHealthHook.Config memory) {
        return ChartHealthHook.Config({
            candlePeriod: PERIOD,
            minRangeTicks: 100,
            neutralFee: 3_000, // 0.30%
            topBuyFee: 1_000, // 0.10%
            bottomBuyFee: 2_000, // 0.20%
            topSellFee: 10_000, // 1%
            bottomSellFee: 20_000, // 2%
            fullDiscountScore: 1 ether,
            maxDiscountBps: 5_000 // 50%
        });
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Swap through the untrusted test router. Returns the LP fee the PoolManager charged.
    function swap(bool isBuy, uint256 amountIn) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap{value: isBuy ? amountIn : 0}(
            key,
            SwapParams(isBuy, -int256(amountIn), isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
        return chargedFee();
    }

    /// @dev Swap as `trader` through the trusted V4Router (exposes msgSender()).
    function trustedSwap(address trader, bool isBuy, uint256 amountIn) internal returns (uint24) {
        bytes memory data = Planner.init()
            .add(
                Actions.SWAP_EXACT_IN_SINGLE,
                abi.encode(IV4Router.ExactInputSingleParams(key, isBuy, uint128(amountIn), 0, ""))
            ).finalizeSwap(isBuy ? eth : token, isBuy ? token : eth, ActionConstants.MSG_SENDER);

        vm.recordLogs();
        vm.prank(trader);
        trustedRouter.executeActions{value: isBuy ? amountIn : 0}(data);
        return chargedFee();
    }

    function chargedFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    /// @dev Big buy from a flat chart: price ends at the top of the range.
    function pump() internal {
        assertEq(swap(true, 10 ether), 3_000); // flat chart -> neutral fee
    }

    /// @dev Pump, then a big sell: price ends at the bottom of the range.
    function pumpAndDump() internal {
        pump();
        assertEq(swap(false, 25 ether), 10_000); // selling from the top -> extractor fee
    }

    // ---------------------------------------------------------------------
    // Fees by zone (no identity needed)
    // ---------------------------------------------------------------------

    function test_flatChart_neutralFee() public {
        assertEq(swap(true, 1 ether), 3_000);
        assertEq(swap(false, 1 ether), 3_000);
    }

    function test_topBuy_topBlasterFee() public {
        pump();
        assertEq(swap(true, 1 ether), 1_000);
    }

    function test_topSell_extractorFee() public {
        pump();
        assertEq(swap(false, 1 ether), 10_000);
    }

    function test_bottomBuy_supporterFee() public {
        pumpAndDump();
        assertEq(swap(true, 1 ether), 2_000);
    }

    function test_bottomSell_paperHandsFee() public {
        pumpAndDump();
        assertEq(swap(false, 1 ether), 20_000);
    }

    function test_rangeSurvivesOneCandle() public {
        pump();
        vm.warp(block.timestamp + PERIOD);
        assertEq(swap(true, 1 ether), 1_000);
    }

    function test_rangeResetsAfterQuietPeriod() public {
        pump();
        vm.warp(block.timestamp + 2 * PERIOD);
        assertEq(swap(true, 1 ether), 3_000);
    }

    // ---------------------------------------------------------------------
    // Score + discount (trusted routers only)
    // ---------------------------------------------------------------------

    function test_untrustedRouter_noScore() public {
        pump();
        swap(true, 1 ether);
        assertEq(hook.score(address(this)), 0);
        assertEq(hook.score(address(swapRouter)), 0);
    }

    function test_trustedRouter_scoresRealTrader() public {
        pump();
        assertEq(trustedSwap(alice, true, 0.25 ether), 1_000); // no score yet -> full fee
        assertEq(hook.score(alice), 0.5 ether); // +2 x 0.25 ETH
        assertEq(hook.discountBps(alice), 2_500); // halfway to fullDiscountScore -> 25% off

        assertEq(trustedSwap(alice, true, 0.25 ether), 750); // 0.10% - 25%
        assertEq(hook.score(alice), 1 ether);
        assertEq(hook.discountBps(alice), 5_000); // max discount reached
    }

    function test_discountAppliesToEveryZone() public {
        pump();
        trustedSwap(alice, true, 1 ether); // score 2 ETH -> 50% off
        assertEq(trustedSwap(alice, false, 0.1 ether), 5_000); // extractor fee 1% -> 0.5%
    }

    function test_negativeScore_noExtraPenalty() public {
        pumpAndDump();
        uint24 fee = trustedSwap(alice, false, 1 ether); // paper hands
        assertEq(fee, 20_000);
        assertLt(hook.score(alice), 0);
        assertEq(hook.discountBps(alice), 0);
    }

    function test_roundTripAtTop_scoresOnlyWhatWasLost() public {
        pump();
        trustedSwap(alice, true, 1 ether); // top blast: +2 per ETH
        uint256 balanceBefore = alice.balance;
        trustedSwap(alice, false, 1 ether); // extract at the top: -2 per ETH
        uint256 ethOut = alice.balance - balanceBefore;
        // Net score is only 2x the ETH lost to fees and price impact, so wash trading can't farm discounts for free
        assertEq(hook.score(alice), 2 * (1 ether - int256(ethOut)));
    }

    // ---------------------------------------------------------------------
    // Config + pool validation
    // ---------------------------------------------------------------------

    function test_rejectsStaticFeePool() public {
        vm.expectRevert();
        initPool(eth, token, hook, 3000, SQRT_PRICE_1_1);
    }
}
