// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title ChartHealthHook
/// @notice Dynamic-fee hook for ETH/TOKEN pools that prices every swap by what it does to the chart.
///
/// The hook tracks the TOKEN price over a rolling window (current + previous candle) and charges:
///
///   |                     | buy TOKEN                | sell TOKEN               |
///   |---------------------|--------------------------|--------------------------|
///   | top 25% of range    | topBuyFee    (top blast) | topSellFee   (extract)   |
///   | middle / flat chart | neutralFee               | neutralFee               |
///   | bottom 25% of range | bottomBuyFee (support)   | bottomSellFee (paper hands) |
///
/// Traders coming through a trusted router (one that exposes the real trader via `msgSender()`)
/// build a public on-chain `score` (+2 top blast, +1 support, -2 extract, -2 paper hands, per ETH)
/// and get up to `maxDiscountBps` off every fee as their score approaches `fullDiscountScore`.
contract ChartHealthHook is BaseHook {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    enum Zone {
        NEUTRAL,
        TOP,
        BOTTOM
    }

    /// @dev Prices are stored as `-poolTick`: pool ticks price TOKEN per ETH, so negating makes higher = stronger TOKEN.
    struct Candle {
        uint64 start;
        int24 high;
        int24 low;
        int24 close;
    }

    struct Chart {
        Candle prev;
        Candle curr;
    }

    struct Config {
        uint64 candlePeriod; // seconds per candle; the range covers the last 1-2 candles
        int24 minRangeTicks; // narrower ranges count as a flat chart (neutral fee, no score)
        uint24 neutralFee; // fees in hundredths of a bip: 3000 = 0.30%, max 1_000_000 = 100%
        uint24 topBuyFee;
        uint24 bottomBuyFee;
        uint24 topSellFee;
        uint24 bottomSellFee;
        uint256 fullDiscountScore; // score (in wei of ETH) that unlocks the max discount
        uint256 maxDiscountBps; // max discount off the fee: 5000 = 50%, 10000 = 100%
    }

    int256 public constant ZONE_BPS = 2_500;

    uint64 public immutable candlePeriod;
    int24 public immutable minRangeTicks;
    uint24 public immutable neutralFee;
    uint24 public immutable topBuyFee;
    uint24 public immutable bottomBuyFee;
    uint24 public immutable topSellFee;
    uint24 public immutable bottomSellFee;
    uint256 public immutable fullDiscountScore;
    uint256 public immutable maxDiscountBps;

    mapping(address router => bool) public trustedRouter;
    mapping(address trader => int256) public score;
    mapping(PoolId => Chart) public charts;

    event ScoreUpdated(address indexed trader, int256 change, int256 newScore);

    error InvalidConfig();
    error InvalidPool();

    constructor(IPoolManager _manager, Config memory c, address[] memory routers) BaseHook(_manager) {
        if (
            c.candlePeriod == 0 || c.fullDiscountScore == 0 || c.maxDiscountBps > 10_000
                || c.neutralFee > LPFeeLibrary.MAX_LP_FEE || c.topBuyFee > LPFeeLibrary.MAX_LP_FEE
                || c.bottomBuyFee > LPFeeLibrary.MAX_LP_FEE || c.topSellFee > LPFeeLibrary.MAX_LP_FEE
                || c.bottomSellFee > LPFeeLibrary.MAX_LP_FEE
        ) revert InvalidConfig();

        candlePeriod = c.candlePeriod;
        minRangeTicks = c.minRangeTicks;
        neutralFee = c.neutralFee;
        topBuyFee = c.topBuyFee;
        bottomBuyFee = c.bottomBuyFee;
        topSellFee = c.topSellFee;
        bottomSellFee = c.bottomSellFee;
        fullDiscountScore = c.fullDiscountScore;
        maxDiscountBps = c.maxDiscountBps;

        for (uint256 i; i < routers.length; i++) {
            trustedRouter[routers[i]] = true;
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @dev Only ETH/TOKEN dynamic-fee pools. Seeds the chart with the starting price.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        if (!key.currency0.isAddressZero() || !key.fee.isDynamicFee()) revert InvalidPool();
        Candle memory c = Candle(_bucket(), -tick, -tick, -tick);
        charts[key.toId()] = Chart(c, c);
        return this.afterInitialize.selector;
    }

    /// @dev Update the chart with the pre-swap price, then charge the fee for this zone and direction.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        Chart storage chart = charts[id];
        _record(chart, -tick);

        uint24 fee = _baseFee(_zone(chart), params.zeroForOne);
        fee -= uint24(fee * discountBps(_trader(sender)) / 10_000);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Score trusted traders by ETH volume. The zone is unchanged since beforeSwap.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        address trader = _trader(sender);
        int256 weight = _weight(_zone(charts[key.toId()]), params.zeroForOne);

        if (trader != address(0) && weight != 0) {
            int256 eth = delta.amount0();
            int256 change = weight * (eth < 0 ? -eth : eth);
            score[trader] += change;
            emit ScoreUpdated(trader, change, score[trader]);
        }
        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Discount off the fee, scaling linearly with a positive score up to `maxDiscountBps`.
    function discountBps(address trader) public view returns (uint256) {
        int256 s = score[trader];
        if (s <= 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positive = uint256(s); // safe: s > 0
        if (positive >= fullDiscountScore) return maxDiscountBps;
        return positive * maxDiscountBps / fullDiscountScore;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev The real trader for trusted routers, address(0) (no score, no discount) for everyone else.
    function _trader(address sender) internal view returns (address) {
        return trustedRouter[sender] ? IMsgSender(sender).msgSender() : address(0);
    }

    function _baseFee(Zone zone, bool isBuy) internal view returns (uint24) {
        if (zone == Zone.TOP) return isBuy ? topBuyFee : topSellFee;
        if (zone == Zone.BOTTOM) return isBuy ? bottomBuyFee : bottomSellFee;
        return neutralFee;
    }

    function _weight(Zone zone, bool isBuy) internal pure returns (int256) {
        if (zone == Zone.TOP) return isBuy ? int256(2) : -2;
        if (zone == Zone.BOTTOM) return isBuy ? int256(1) : -2;
        return 0;
    }

    function _bucket() internal view returns (uint64) {
        return uint64(block.timestamp - block.timestamp % candlePeriod);
    }

    /// @dev Record the current price into the candle it was reached in, then roll to a new candle if time has passed.
    function _record(Chart storage chart, int24 price) internal {
        Candle storage curr = chart.curr;
        if (price > curr.high) curr.high = price;
        if (price < curr.low) curr.low = price;
        curr.close = price;

        uint64 bucket = _bucket();
        if (bucket == curr.start) return;

        if (bucket == curr.start + candlePeriod) {
            chart.prev = curr;
        } else {
            // No trades for a whole candle: the price sat flat
            chart.prev = Candle(bucket - candlePeriod, price, price, price);
        }
        chart.curr = Candle(bucket, price, price, price);
    }

    function _zone(Chart storage chart) internal view returns (Zone) {
        int256 high = chart.prev.high > chart.curr.high ? chart.prev.high : chart.curr.high;
        int256 low = chart.prev.low < chart.curr.low ? chart.prev.low : chart.curr.low;
        int256 width = high - low;
        if (width < minRangeTicks) return Zone.NEUTRAL;

        int256 band = width * ZONE_BPS / 10_000;
        int256 price = chart.curr.close;
        if (price >= high - band) return Zone.TOP;
        if (price <= low + band) return Zone.BOTTOM;
        return Zone.NEUTRAL;
    }
}
