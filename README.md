# Chart Health Hook

A Uniswap v4 hook that judges every swap by what it does to the **health of the chart**, and stamps the trader with a **soulbound ERC-1155 badge**.

Built for the Uniswap v4 Hooks Incubator ("Build your first hook"), on top of [haardikk21/points-hook](https://github.com/haardikk21/points-hook). The original `PointsHook` is kept in `src/` for reference.

## The idea

Top blasters push the chart up and get rewarded. Dip buyers support the chart and get rewarded. Selling into strength marks you as an extractor, and dumping at the bottom marks you as paper hands.

| Price zone (vs. recent range) | Buy TOKEN | Sell TOKEN |
|---|---|---|
| **Top** (upper 25%) | 🚀 `TOP_BLASTER` (id 0, score +2x) | 🧛 `EXTRACTOR` (id 2, score −1x) |
| **Bottom** (lower 25%) | 💎 `SUPPORTER` (id 1, score +1x) | 🧻 `PAPER_HANDS` (id 3, score −2x) |
| Middle, or flat chart | nothing | nothing |

- **Badge amount** = ETH volume of the swap (in wei).
- **`chartScore(address)`** is one signed reputation number per wallet: the sum of `weight × ETH volume` over all badges earned. Positive means supportive, negative means extractive.
- **Soulbound.** `safeTransferFrom`, `safeBatchTransferFrom` and `setApprovalForAll` all revert with `Soulbound()`. Your badges stay with you.

A project can use the badges or the score to airdrop to supporters, gate perks, or flag extractors.

## How "high" and "low" are measured

The hook keeps two **candles** (fixed time buckets, `candlePeriod` seconds each) per pool: the previous one and the current one. Each candle tracks the high, low and close of the TOKEN price in ticks.

- The **recent range** is the min low and max high across both candles, so it covers the last 1–2 candle periods.
- A swap is classified by the **pre-swap price**, meaning where the chart was when you traded. In v4, price only moves through swaps, so this is the last recorded close.
- If the range is narrower than `minRangeTicks`, the chart counts as flat and no badges are minted.
- If no one trades for a full candle period, the old range rolls out of the window.

Pool ticks price currency1 in currency0 (TOKEN per ETH), so the hook stores `tokenTick = -poolTick`. Higher then means a stronger TOKEN.

## Hook details

- Permissions: `afterInitialize` (seeds the first candle) and `afterSwap` (classifies the swap, mints the badge, updates the candle).
- Supported pools: ETH/TOKEN pools (`currency0` = native ETH). Other pools are ignored.
- The trader is identified the same way as in PointsHook: `hookData = abi.encode(userAddress)`. With no hookData, no badges are minted.
- Constructor: `ChartHealthHook(IPoolManager manager, uint64 candlePeriod, int24 minRangeTicks)`.
- Views: `getRange(poolId)`, `currentZone(poolId)`, `getChart(poolId)`, `chartScore(user)`, `badgeWeight(badge)`.
- Event: `BadgeEarned(user, poolId, badge, ethAmount, newScore)`.

## Run it

```bash
git clone --recursive https://github.com/Markeljan/chart-health-hook
cd chart-health-hook
forge test
```

The tests in `test/ChartHealthHook.t.sol` cover:

- a flat chart minting no badges
- range tracking
- each of the four badges and its score weight
- dumping from the top counting as extraction
- no hookData meaning no badges
- the candle window surviving one period and resetting after a quiet period
- soulbound transfer and approval reverts
- score accumulating across badges

## Limitations and ideas

- `hookData` is self-reported, so a router can claim any address. A production version should identify the trader through a trusted router or `msg.sender` allowlist.
- Classification uses a simple 2-candle high/low range. TWAP, longer ring buffers, or momentum indicators could replace it.
- Wash trading can farm positive badges. A real deployment would want fees, cooldowns, or volume caps.
