// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @title ChartHealthHook
/// @notice A Uniswap v4 hook that judges every swap by what it does to the "health of the chart".
///
/// For ETH/TOKEN pools (currency0 = native ETH) the hook keeps a rolling price range made of the
/// current and previous "candles" (fixed time buckets). Before each swap moves the price, the hook
/// looks at where the TOKEN price sits inside that range:
///
///   - top zone    (upper 25% of the range) -> the chart is strong / trending up
///   - bottom zone (lower 25% of the range) -> the chart is weak / dipping
///
/// and mints a soulbound ERC-1155 badge to the trader:
///
///   | zone   | buy TOKEN          | sell TOKEN          |
///   |--------|--------------------|---------------------|
///   | top    | TOP_BLASTER  (+2x) | EXTRACTOR    (-1x)  |
///   | bottom | SUPPORTER    (+1x) | PAPER_HANDS  (-2x)  |
///
/// The badge amount equals the ETH volume of the swap. Every badge also moves a single signed
/// `chartScore` per wallet using the weights above, so projects can use either the individual
/// badges or one reputation number to reward supporters and flag extractors.
///
/// Badges are non-transferable: all transfers and approvals revert.
contract ChartHealthHook is BaseHook, ERC1155 {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Badge {
        TOP_BLASTER, // id 0: bought while the chart was ripping
        SUPPORTER, // id 1: bought the dip
        EXTRACTOR, // id 2: sold into strength
        PAPER_HANDS // id 3: sold the bottom
    }

    enum Zone {
        NEUTRAL,
        TOP,
        BOTTOM
    }

    /// @notice One time bucket of TOKEN price action, expressed in "token ticks".
    /// @dev Pool ticks price currency1 in currency0 (TOKEN per ETH), so a higher TOKEN price
    ///      means a lower pool tick. We store `tokenTick = -poolTick` so that high == strong.
    struct Candle {
        uint64 start;
        int24 high;
        int24 low;
        int24 close;
    }

    struct ChartState {
        Candle prev;
        Candle curr;
        bool hasPrev;
    }

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    /// @notice Width of the top / bottom zones as a share of the range (basis points).
    uint256 public constant ZONE_BPS = 2_500;

    /// @notice Length of one candle in seconds.
    uint64 public immutable candlePeriod;

    /// @notice Range (in ticks) below which the chart is considered flat and no badges are minted.
    int24 public immutable minRangeTicks;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    mapping(PoolId => ChartState) internal _charts;

    /// @notice Single reputation score per wallet. Positive = supportive, negative = extractive.
    mapping(address => int256) public chartScore;

    // ---------------------------------------------------------------------
    // Events / errors
    // ---------------------------------------------------------------------

    event BadgeEarned(
        address indexed user, PoolId indexed poolId, Badge indexed badge, uint256 ethAmount, int256 newScore
    );

    error Soulbound();

    constructor(IPoolManager _manager, uint64 _candlePeriod, int24 _minRangeTicks) BaseHook(_manager) {
        candlePeriod = _candlePeriod;
        minRangeTicks = _minRangeTicks;
    }

    // ---------------------------------------------------------------------
    // Hook config
    // ---------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        int24 tokenTick = -tick;
        _charts[key.toId()].curr = Candle({start: _bucket(block.timestamp), high: tokenTick, low: tokenTick, close: tokenTick});
        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Only ETH/TOKEN pools are tracked
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        PoolId poolId = key.toId();
        ChartState storage chart = _charts[poolId];

        // Roll candles forward if time has passed, then classify using the pre-swap price.
        // Price in v4 only moves through swaps, so the last candle close is the pre-swap price.
        _roll(chart);
        Zone zone = _zone(chart, chart.curr.close);

        // Record the post-swap price into the current candle
        (, int24 tick,,) = _getSlot0(poolId);
        _record(chart.curr, -tick);

        if (zone == Zone.NEUTRAL) return (this.afterSwap.selector, 0);

        // ETH volume of the swap, in either direction
        int128 amount0 = delta.amount0();
        uint256 ethAmount = uint256(int256(amount0 < 0 ? -amount0 : amount0));

        // zeroForOne = ETH in, TOKEN out = buying TOKEN
        Badge badge;
        if (swapParams.zeroForOne) {
            badge = zone == Zone.TOP ? Badge.TOP_BLASTER : Badge.SUPPORTER;
        } else {
            badge = zone == Zone.TOP ? Badge.EXTRACTOR : Badge.PAPER_HANDS;
        }

        _award(poolId, hookData, badge, ethAmount);
        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Rolling TOKEN price range (in token ticks) used to judge swaps.
    function getRange(PoolId poolId) public view returns (int24 low, int24 high) {
        ChartState storage chart = _charts[poolId];
        return _range(chart);
    }

    /// @notice Which zone a swap would be judged in right now.
    function currentZone(PoolId poolId) external view returns (Zone) {
        ChartState storage chart = _charts[poolId];
        return _zone(chart, chart.curr.close);
    }

    function getChart(PoolId poolId) external view returns (ChartState memory) {
        return _charts[poolId];
    }

    function badgeWeight(Badge badge) public pure returns (int256) {
        if (badge == Badge.TOP_BLASTER) return 2;
        if (badge == Badge.SUPPORTER) return 1;
        if (badge == Badge.EXTRACTOR) return -1;
        return -2; // PAPER_HANDS
    }

    function uri(uint256 id) public pure override returns (string memory) {
        if (id == uint256(Badge.TOP_BLASTER)) return "data:,Top Blaster";
        if (id == uint256(Badge.SUPPORTER)) return "data:,Supporter";
        if (id == uint256(Badge.EXTRACTOR)) return "data:,Extractor";
        if (id == uint256(Badge.PAPER_HANDS)) return "data:,Paper Hands";
        return "";
    }

    // ---------------------------------------------------------------------
    // Soulbound: disable transfers and approvals
    // ---------------------------------------------------------------------

    function setApprovalForAll(address, bool) public pure override {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) public pure override {
        revert Soulbound();
    }

    function safeBatchTransferFrom(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        public
        pure
        override
    {
        revert Soulbound();
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _award(PoolId poolId, bytes calldata hookData, Badge badge, uint256 ethAmount) internal {
        // Same convention as PointsHook: the trader's address is passed in hookData
        if (hookData.length == 0 || ethAmount == 0) return;
        address user = abi.decode(hookData, (address));
        if (user == address(0)) return;

        int256 newScore = chartScore[user] + badgeWeight(badge) * int256(ethAmount);
        chartScore[user] = newScore;

        _mint(user, uint256(badge), ethAmount, "");
        emit BadgeEarned(user, poolId, badge, ethAmount, newScore);
    }

    function _bucket(uint256 timestamp) internal view returns (uint64) {
        return uint64(timestamp - (timestamp % candlePeriod));
    }

    /// @dev Start a new candle when the current one has expired.
    function _roll(ChartState storage chart) internal {
        uint64 nowBucket = _bucket(block.timestamp);
        Candle memory curr = chart.curr;
        if (nowBucket == curr.start) return;

        if (nowBucket == curr.start + candlePeriod) {
            // Consecutive candle: previous candle keeps its full range
            chart.prev = curr;
        } else {
            // Gap with no trading: the price sat flat at the last close for the whole previous period
            chart.prev = Candle({start: nowBucket - candlePeriod, high: curr.close, low: curr.close, close: curr.close});
        }
        chart.hasPrev = true;
        chart.curr = Candle({start: nowBucket, high: curr.close, low: curr.close, close: curr.close});
    }

    function _record(Candle storage candle, int24 tokenTick) internal {
        if (tokenTick > candle.high) candle.high = tokenTick;
        if (tokenTick < candle.low) candle.low = tokenTick;
        candle.close = tokenTick;
    }

    function _range(ChartState storage chart) internal view returns (int24 low, int24 high) {
        low = chart.curr.low;
        high = chart.curr.high;
        if (chart.hasPrev) {
            if (chart.prev.low < low) low = chart.prev.low;
            if (chart.prev.high > high) high = chart.prev.high;
        }
    }

    function _zone(ChartState storage chart, int24 tokenTick) internal view returns (Zone) {
        (int24 low, int24 high) = _range(chart);
        int256 width = int256(high) - int256(low);
        if (width < int256(minRangeTicks)) return Zone.NEUTRAL;

        int256 band = width * int256(ZONE_BPS) / 10_000;
        if (int256(tokenTick) >= int256(high) - band) return Zone.TOP;
        if (int256(tokenTick) <= int256(low) + band) return Zone.BOTTOM;
        return Zone.NEUTRAL;
    }

    function _getSlot0(PoolId poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return StateLibrary.getSlot0(poolManager, poolId);
    }
}
