// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IMsgSender} from "v4-periphery/src/interfaces/IMsgSender.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title ChartHealthHook
/// @notice Dynamic-fee hook for ETH/TOKEN pools that prices every swap by what it does to the chart.
///
/// The hook tracks the TOKEN price range over the current + previous candle and splits it into zones:
///
///   |        | buy TOKEN                 | sell TOKEN                     |
///   |--------|---------------------------|--------------------------------|
///   | top    | topBuyFee    (top blaster) | topSellFee    (extractor)      |
///   | middle | neutralFee                | neutralFee                     |
///   | bottom | bottomBuyFee (supporter)  | bottomSellFee (paper hands)    |
///
/// A swap is judged on both where it starts and where it is estimated to end: buys get the cheaper of
/// the two zones, sells pay the pricier one. One big dump from the middle pays the paper-hands fee.
///
/// Traders coming through a trusted router (one exposing the real trader via `msgSender()`) build a
/// public, decaying `scoreOf` (zone weight x ETH volume) that unlocks a discount on non-penalty trades.
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

    struct Score {
        int128 value;
        uint64 updatedAt;
    }

    struct Config {
        // Chart
        uint32 candlePeriod; // seconds per candle; the range covers the last 1-2 candles
        int24 minRangeTicks; // narrower ranges count as a flat chart (neutral)
        uint16 zoneBps; // width of the top and bottom zones: 2500 = 25% of the range each
        // Fees, in hundredths of a bip: 3000 = 0.30%, 100_000 = 10%, max 1_000_000 = 100%
        uint24 neutralFee;
        uint24 topBuyFee;
        uint24 bottomBuyFee;
        uint24 topSellFee;
        uint24 bottomSellFee;
        // Score per ETH of volume
        int16 topBuyWeight;
        int16 bottomBuyWeight;
        int16 topSellWeight;
        int16 bottomSellWeight;
        // Discount
        uint16 maxDiscountBps; // max discount on non-penalty trades: 5000 = 50%
        uint32 scoreHalfLife; // seconds for a score to halve; 0 = never decays
        uint128 fullDiscountScore; // score (wei of ETH) that unlocks the max discount
    }

    /// @dev Transient slot carrying the swap's score weight from beforeSwap to afterSwap.
    uint256 private constant WEIGHT_SLOT = 0x8d3a3c9e2f6a5b1c4d7e0f9a8b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c;

    Config internal config;
    mapping(address router => bool) public trustedRouter;
    mapping(PoolId => Chart) public charts;
    mapping(address trader => Score) public scores;

    event ScoreUpdated(address indexed trader, int256 change, int256 newScore);

    error InvalidConfig();
    error InvalidPool();

    constructor(IPoolManager _manager, Config memory c, address[] memory routers) BaseHook(_manager) {
        if (
            c.candlePeriod == 0 || c.zoneBps == 0 || c.zoneBps > 5_000 || c.maxDiscountBps > 10_000
                || c.fullDiscountScore == 0 || c.neutralFee > LPFeeLibrary.MAX_LP_FEE
                || c.topBuyFee > LPFeeLibrary.MAX_LP_FEE || c.bottomBuyFee > LPFeeLibrary.MAX_LP_FEE
                || c.topSellFee > LPFeeLibrary.MAX_LP_FEE || c.bottomSellFee > LPFeeLibrary.MAX_LP_FEE
        ) revert InvalidConfig();

        config = c;
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
        Candle memory c = Candle(_bucket(config.candlePeriod), -tick, -tick, -tick);
        charts[key.toId()] = Chart(c, c);
        return this.afterInitialize.selector;
    }

    /// @dev Judge the swap by where it starts and ends, and charge that zone's fee.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        Config memory c = config;
        bool isBuy = params.zeroForOne;
        Zone zone = _judgeSwap(key.toId(), params, c);

        int256 weight = _weight(zone, isBuy, c);
        uint24 fee = _fee(zone, isBuy, c);
        // Loyalty discounts never apply to penalty trades
        if (weight >= 0) fee -= uint24(fee * discountBps(_trader(sender)) / 10_000);

        assembly ("memory-safe") {
            tstore(WEIGHT_SLOT, weight)
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Score trusted traders: weight x ETH volume.
    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        int256 weight;
        assembly ("memory-safe") {
            weight := tload(WEIGHT_SLOT)
        }
        address trader = _trader(sender);

        if (trader != address(0) && weight != 0) {
            int256 eth = delta.amount0();
            int256 change = weight * (eth < 0 ? -eth : eth);
            int256 newScore = scoreOf(trader) + change;
            scores[trader] = Score(SafeCast.toInt128(newScore), uint64(block.timestamp));
            emit ScoreUpdated(trader, change, newScore);
        }
        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getConfig() external view returns (Config memory) {
        return config;
    }

    /// @notice Current score after decay: halves every `scoreHalfLife`, linear in between.
    function scoreOf(address trader) public view returns (int256) {
        Score memory s = scores[trader];
        uint256 halfLife = config.scoreHalfLife;
        if (halfLife == 0) return s.value;

        uint256 elapsed = block.timestamp - s.updatedAt;
        if (elapsed >= halfLife * 128) return 0;
        int256 v = s.value / SafeCast.toInt256(2 ** (elapsed / halfLife));
        return v - v * SafeCast.toInt256(elapsed % halfLife) / SafeCast.toInt256(2 * halfLife);
    }

    /// @notice Discount off non-penalty fees, scaling linearly with a positive score up to `maxDiscountBps`.
    function discountBps(address trader) public view returns (uint256) {
        int256 s = scoreOf(trader);
        if (s <= 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 positive = uint256(s); // safe: s > 0
        if (positive >= config.fullDiscountScore) return config.maxDiscountBps;
        return positive * config.maxDiscountBps / config.fullDiscountScore;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev The real trader for trusted routers, address(0) (no score, no discount) for everyone else.
    function _trader(address sender) internal view returns (address) {
        return trustedRouter[sender] ? IMsgSender(sender).msgSender() : address(0);
    }

    function _fee(Zone zone, bool isBuy, Config memory c) internal pure returns (uint24) {
        if (zone == Zone.TOP) return isBuy ? c.topBuyFee : c.topSellFee;
        if (zone == Zone.BOTTOM) return isBuy ? c.bottomBuyFee : c.bottomSellFee;
        return c.neutralFee;
    }

    function _weight(Zone zone, bool isBuy, Config memory c) internal pure returns (int256) {
        if (zone == Zone.TOP) return isBuy ? c.topBuyWeight : c.topSellWeight;
        if (zone == Zone.BOTTOM) return isBuy ? c.bottomBuyWeight : c.bottomSellWeight;
        return 0;
    }

    function _bucket(uint32 period) internal view returns (uint64) {
        return uint64(block.timestamp - block.timestamp % period);
    }

    /// @dev Record the current price into the candle it was reached in, then roll to a new candle if time has passed.
    function _record(Chart storage chart, int24 price, uint32 period) internal {
        Candle storage curr = chart.curr;
        if (price > curr.high) curr.high = price;
        if (price < curr.low) curr.low = price;
        curr.close = price;

        uint64 bucket = _bucket(period);
        if (bucket == curr.start) return;

        if (bucket == curr.start + period) {
            chart.prev = curr;
        } else {
            // No trades for a whole candle: the price sat flat
            chart.prev = Candle(bucket - period, price, price, price);
        }
        chart.curr = Candle(bucket, price, price, price);
    }

    /// @dev Record the pre-swap price into the chart, then judge the swap by its start and estimated end.
    function _judgeSwap(PoolId id, SwapParams calldata params, Config memory c) internal returns (Zone) {
        (uint160 sqrtPrice, int24 tick,,) = poolManager.getSlot0(id);
        Chart storage chart = charts[id];
        _record(chart, -tick, c.candlePeriod);
        int24 endPrice = -_estimateTickAfter(sqrtPrice, poolManager.getLiquidity(id), params);
        return _judge(chart, endPrice, params.zeroForOne, c);
    }

    /// @dev Zone of the swap's start and estimated end within the range (extended by the end price).
    ///      Buys get the cheaper zone they touch, sells pay the pricier one.
    function _judge(Chart storage chart, int256 endPrice, bool isBuy, Config memory c) internal view returns (Zone) {
        int256 high = chart.prev.high > chart.curr.high ? chart.prev.high : chart.curr.high;
        int256 low = chart.prev.low < chart.curr.low ? chart.prev.low : chart.curr.low;
        if (endPrice > high) high = endPrice;
        if (endPrice < low) low = endPrice;

        Zone startZone = _zoneOf(chart.curr.close, low, high, c);
        Zone endZone = _zoneOf(endPrice, low, high, c);
        uint24 startFee = _fee(startZone, isBuy, c);
        uint24 endFee = _fee(endZone, isBuy, c);
        return (isBuy ? startFee <= endFee : startFee >= endFee) ? startZone : endZone;
    }

    function _zoneOf(int256 price, int256 low, int256 high, Config memory c) internal pure returns (Zone) {
        int256 width = high - low;
        if (width < c.minRangeTicks) return Zone.NEUTRAL;
        int256 band = width * int256(uint256(c.zoneBps)) / 10_000;
        if (price >= high - band) return Zone.TOP;
        if (price <= low + band) return Zone.BOTTOM;
        return Zone.NEUTRAL;
    }

    /// @dev Estimate the pool tick after the swap, assuming the current in-range liquidity holds and
    ///      clamping to the swap's price limit. Exact for single-range liquidity, an estimate otherwise.
    function _estimateTickAfter(uint160 sqrtPrice, uint128 liquidity, SwapParams calldata p)
        internal
        pure
        returns (int24)
    {
        if (liquidity == 0) return TickMath.getTickAtSqrtPrice(sqrtPrice);

        bool exactIn = p.amountSpecified < 0;
        uint256 amount = uint256(exactIn ? -p.amountSpecified : p.amountSpecified);
        if (amount > type(uint128).max) amount = type(uint128).max; // anything larger just runs to the price limit

        uint256 next;
        if (p.zeroForOne == exactIn) {
            // Specified amount is ETH (currency0): price moves to L * P / (L +- amount * P)
            uint256 d = FullMath.mulDiv(amount, sqrtPrice, FixedPoint96.Q96);
            if (exactIn) next = FullMath.mulDiv(liquidity, sqrtPrice, liquidity + d);
            else next = d >= liquidity ? type(uint160).max : FullMath.mulDiv(liquidity, sqrtPrice, liquidity - d);
        } else {
            // Specified amount is TOKEN (currency1): price moves by amount / L
            uint256 d = FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity);
            if (exactIn) next = sqrtPrice + d;
            else next = d >= sqrtPrice ? 0 : sqrtPrice - d;
        }

        // The swap stops at its price limit (always strictly inside the valid price range)
        if (p.zeroForOne ? next < p.sqrtPriceLimitX96 : next > p.sqrtPriceLimitX96) next = p.sqrtPriceLimitX96;
        return TickMath.getTickAtSqrtPrice(SafeCast.toUint160(next));
    }
}
