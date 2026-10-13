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
import {Planner} from "v4-periphery/test/shared/Planner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {ChartHealthHook} from "../src/ChartHealthHook.sol";
import {ChartHealthPresets} from "../src/ChartHealthPresets.sol";

contract ChartHealthHookTest is Test, Deployers {
    ChartHealthHook hook;
    MockV4Router trustedRouter;
    Currency eth = Currency.wrap(address(0));
    Currency token;

    address alice = makeAddr("alice");
    uint160 constant FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint32 constant PERIOD = 1 hours;

    // Fees used in tests
    uint24 constant NEUTRAL = 3_000; // 0.30%
    uint24 constant TOP_BUY = 1_000; // 0.10%
    uint24 constant BOTTOM_BUY = 2_000; // 0.20%
    uint24 constant TOP_SELL = 10_000; // 1%
    uint24 constant BOTTOM_SELL = 20_000; // 2%

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
        deployCodeTo("ChartHealthHook.sol", abi.encode(manager, testConfig(), routers), address(FLAGS));
        hook = ChartHealthHook(address(FLAGS));

        (key,) = initPool(eth, token, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Single wide range: 10 ETH moves the price ~500 ticks
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(6000), 100 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            key, ModifyLiquidityParams(-6000, 6000, int256(uint256(liquidity)), 0), ZERO_BYTES
        );
    }

    function testConfig() internal pure returns (ChartHealthHook.Config memory) {
        return ChartHealthHook.Config({
            candlePeriod: PERIOD,
            minRangeTicks: 100,
            zoneBps: 2_500,
            neutralFee: NEUTRAL,
            topBuyFee: TOP_BUY,
            bottomBuyFee: BOTTOM_BUY,
            topSellFee: TOP_SELL,
            bottomSellFee: BOTTOM_SELL,
            topBuyWeight: 2,
            bottomBuyWeight: 1,
            topSellWeight: -2,
            bottomSellWeight: -2,
            maxDiscountBps: 5_000,
            scoreHalfLife: 1 days,
            fullDiscountScore: 1 ether
        });
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Exact-input swap through the untrusted test router. Returns the LP fee the PoolManager charged.
    function swap(bool isBuy, uint256 amountIn) internal returns (uint24) {
        return swapExact(isBuy, -int256(amountIn));
    }

    function swapExact(bool isBuy, int256 amountSpecified) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap{value: isBuy ? uint256(-amountSpecified) : 0}(
            key,
            SwapParams(isBuy, amountSpecified, isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ZERO_BYTES
        );
        return chargedFee();
    }

    /// @dev Exact-input swap as `trader` through the trusted V4Router (exposes msgSender()).
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

    /// @dev A breakout buy from a flat chart ends at the top: top blaster.
    function pump() internal {
        assertEq(swap(true, 10 ether), TOP_BUY);
    }

    /// @dev Pump, then a big sell that ends at the bottom: paper hands.
    function pumpAndDump() internal {
        pump();
        assertEq(swap(false, 25 ether), BOTTOM_SELL);
    }

    // ---------------------------------------------------------------------
    // Fees by zone (no identity needed)
    // ---------------------------------------------------------------------

    function test_flatChart_smallSwapsAreNeutral() public {
        assertEq(swap(true, 1 ether), NEUTRAL);
        assertEq(swap(false, 1 ether), NEUTRAL);
    }

    function test_topBuy_topBlasterFee() public {
        pump();
        assertEq(swap(true, 1 ether), TOP_BUY);
    }

    function test_topSell_extractorFee() public {
        pump();
        assertEq(swap(false, 1 ether), TOP_SELL);
    }

    function test_bottomBuy_supporterFee() public {
        pumpAndDump();
        assertEq(swap(true, 1 ether), BOTTOM_BUY);
    }

    function test_bottomSell_paperHandsFee() public {
        pumpAndDump();
        assertEq(swap(false, 1 ether), BOTTOM_SELL);
    }

    // ---------------------------------------------------------------------
    // Judged by where the swap ends
    // ---------------------------------------------------------------------

    function test_bigDumpFromFlatChart_paysPaperHands() public {
        assertEq(swap(false, 10 ether), BOTTOM_SELL);
    }

    function test_bigDumpFromMiddle_paysPaperHands() public {
        pump();
        swap(false, 5 ether); // back to the middle of the range
        assertEq(swap(false, 0.1 ether), NEUTRAL); // a small sell here is neutral...
        assertEq(swap(false, 25 ether), BOTTOM_SELL); // ...but a dump that ends at the bottom is not
    }

    function test_exactOutputDump_paysPaperHands() public {
        assertEq(swapExact(false, 9 ether), BOTTOM_SELL); // sell TOKEN for exactly 9 ETH out
    }

    function test_dipBuyThatLiftsTheChart_keepsSupporterFee() public {
        pumpAndDump();
        assertEq(swap(true, 12 ether), BOTTOM_BUY); // buys get the cheaper zone they touch...
        assertEq(swap(false, 0.1 ether), NEUTRAL); // ...even when they lift the price out of the bottom
    }

    // ---------------------------------------------------------------------
    // Candle window
    // ---------------------------------------------------------------------

    function test_rangeSurvivesOneCandle() public {
        pump();
        vm.warp(block.timestamp + PERIOD);
        assertEq(swap(true, 1 ether), TOP_BUY);
    }

    function test_rangeResetsAfterQuietPeriod() public {
        pump();
        vm.warp(block.timestamp + 2 * PERIOD);
        assertEq(swap(true, 1 ether), NEUTRAL);
    }

    // ---------------------------------------------------------------------
    // Score + discount (trusted routers only)
    // ---------------------------------------------------------------------

    function test_untrustedRouter_noScore() public {
        pump();
        assertEq(hook.scoreOf(address(this)), 0);
        assertEq(hook.scoreOf(address(swapRouter)), 0);
    }

    function test_trustedRouter_scoresRealTraderWithDiscount() public {
        pump();
        assertEq(trustedSwap(alice, true, 0.25 ether), TOP_BUY); // no score yet: full fee
        assertEq(hook.scoreOf(alice), 0.5 ether); // +2 x 0.25 ETH
        assertEq(hook.discountBps(alice), 2_500); // halfway to fullDiscountScore: 25% off

        assertEq(trustedSwap(alice, true, 0.25 ether), TOP_BUY * 3 / 4);
        assertEq(hook.discountBps(alice), 5_000); // max discount reached
    }

    function test_discountSkipsPenaltyTrades() public {
        pump();
        trustedSwap(alice, true, 1 ether); // score 2 ETH: max discount
        assertEq(trustedSwap(alice, false, 0.1 ether), TOP_SELL); // extracting still pays full price
    }

    function test_negativeScore_noExtraPenalty() public {
        pumpAndDump();
        assertEq(trustedSwap(alice, false, 1 ether), BOTTOM_SELL);
        assertLt(hook.scoreOf(alice), 0);
        assertEq(hook.discountBps(alice), 0);
    }

    function test_roundTripAtTop_scoresOnlyWhatWasLost() public {
        pump();
        trustedSwap(alice, true, 1 ether);
        uint256 balanceBefore = alice.balance;
        trustedSwap(alice, false, 1 ether);
        uint256 ethOut = alice.balance - balanceBefore;
        // Net score is 2x the ETH lost to fees and price impact: wash trading can't farm discounts for free
        assertEq(hook.scoreOf(alice), 2 * (1 ether - int256(ethOut)));
    }

    function test_scoreDecays() public {
        pump();
        trustedSwap(alice, true, 1 ether); // score 2 ETH
        vm.warp(block.timestamp + 1 days);
        assertEq(hook.scoreOf(alice), 1 ether); // one half-life
        vm.warp(block.timestamp + 12 hours);
        assertEq(hook.scoreOf(alice), 0.75 ether); // linear between halvings
    }

    // ---------------------------------------------------------------------
    // Config + pool validation
    // ---------------------------------------------------------------------

    function test_rejectsStaticFeePool() public {
        vm.expectRevert();
        initPool(eth, token, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_presetsDeploy() public {
        ChartHealthHook.Config[3] memory presets =
            [ChartHealthPresets.trenches(), ChartHealthPresets.diamondHands(), ChartHealthPresets.launchShield()];
        for (uint256 i; i < presets.length; i++) {
            address at = address(FLAGS | uint160(i + 1) << 100);
            deployCodeTo("ChartHealthHook.sol", abi.encode(manager, presets[i], new address[](0)), at);
            assertEq(ChartHealthHook(at).getConfig().bottomSellFee, presets[i].bottomSellFee);
        }
    }
}
