# Chart Health Hook

A Uniswap v4 dynamic-fee hook that charges each swap based on what it does to the chart, and gives loyal, well-timed traders a discount.

- **Buying strength (top blasting) or the dip (supporting)** is cheap.
- **Selling into strength (extracting) or at the bottom (paper hands)** is expensive.
- **Traders with a good track record** get up to a configurable discount on every fee.

Everything is in one contract: [`src/ChartHealthHook.sol`](src/ChartHealthHook.sol).

## How it works

**1. Read the chart.** For each pool, the hook keeps the TOKEN price high and low over a rolling window: the current candle plus the previous one. Before every swap, it places the current price in that range:

- **Top:** the upper 25% of the range.
- **Bottom:** the lower 25%.
- **Neutral:** anywhere in between. A range narrower than `minRangeTicks` counts as a flat chart, so every swap there is neutral.

**2. Charge a fee for that zone and direction** (example defaults):

| Zone | Buy TOKEN | Sell TOKEN |
|---|---|---|
| Top | 0.10% (top blaster) | 1.00% (extractor) |
| Neutral or flat | 0.30% | 0.30% |
| Bottom | 0.20% (supporter) | 2.00% (paper hands) |

The penalty is attached to the trade itself, so it applies to every wallet and every router, aggregators included.

**3. Build a score and earn a discount.** The hook identifies traders who swap through a **trusted router**, meaning one that exposes the real trader via `IMsgSender.msgSender()`, such as Uniswap's Universal Router.

- **Score:** each trusted trade changes the trader's public on-chain `score` by its ETH volume times a weight:

  | Top blaster | Supporter | Extractor | Paper hands |
  |---|---|---|---|
  | +2 | +1 | −2 | −2 |

- **Discount:** grows linearly with a positive score, reaching `maxDiscountBps` at `fullDiscountScore`.
- **Discount-only:** a negative score adds no extra penalty, because a fresh wallet would dodge it. Bad timing is already priced into each trade.
- **Other routers:** swaps through any other router pay the zone fee, with no score and no discount.

Any contract can read `score(address)` and `discountBps(address)`, for example to run airdrops, gate perks, or label wallets.

## Configuration

All settings are fixed at deployment through the `Config` struct:

| Field | Example | Meaning |
|---|---|---|
| `candlePeriod` | `3600` | Candle length in seconds. The range covers the last 1–2 candles. |
| `minRangeTicks` | `100` | Below this range width, the chart counts as flat. |
| `neutralFee` | `3000` | Fees are in hundredths of a bip: `3000` = 0.30%, `100000` = 10%. Max `1000000` (100%). |
| `topBuyFee`, `bottomBuyFee`, `topSellFee`, `bottomSellFee` | `1000`, `2000`, `10000`, `20000` | Fee per zone and direction. |
| `fullDiscountScore` | `1 ether` | Score needed for the max discount. A good starting point is about 10× a typical buy. |
| `maxDiscountBps` | `5000` | Max discount: `5000` = 50% off, `10000` = 100% off. |

Trusted routers are passed to the constructor as an `address[]`.

The pool must be **ETH/TOKEN** (`currency0` = native ETH) and created with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. Initializing any other pool reverts with `InvalidPool`.

Because a hook is permanently tied to its pools, changing the settings means deploying a new hook and pool.

## Run

```bash
git clone --recursive https://github.com/Markeljan/chart-health-hook
cd chart-health-hook
forge test
```

The tests use Uniswap's real `V4Router` (`MockV4Router` from v4-periphery) as the trusted router and `PoolSwapTest` as an untrusted one. They read the fee actually charged from the PoolManager's `Swap` event.

To deploy, mine a hook address with the `AFTER_INITIALIZE`, `BEFORE_SWAP` and `AFTER_SWAP` flags (for example with v4-periphery's `HookMiner`).

---

Built for the Uniswap v4 Hooks Incubator. Started from [haardikk21/points-hook](https://github.com/haardikk21/points-hook).
