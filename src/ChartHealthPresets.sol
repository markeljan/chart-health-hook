// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ChartHealthHook} from "./ChartHealthHook.sol";

/// @title ChartHealthPresets
/// @notice Ready-made configs for the ChartHealthHook. Fees are in hundredths of a bip (10_000 = 1%).
library ChartHealthPresets {
    /// @notice 🔥 Trenches: fast degen memecoin. Sending it is nearly free, dumping the bottom costs 8%.
    function trenches() internal pure returns (ChartHealthHook.Config memory) {
        return ChartHealthHook.Config({
            candlePeriod: 15 minutes,
            minRangeTicks: 1_000, // ~10% move before zones kick in
            zoneBps: 2_500,
            neutralFee: 10_000, // 1%
            topBuyFee: 2_500, // 0.25%
            bottomBuyFee: 5_000, // 0.5%
            topSellFee: 30_000, // 3%
            bottomSellFee: 80_000, // 8%
            topBuyWeight: 2,
            bottomBuyWeight: 1,
            topSellWeight: -2,
            bottomSellWeight: -2,
            maxDiscountBps: 7_500, // 75% off
            scoreHalfLife: 3 days,
            fullDiscountScore: 3 ether
        });
    }

    /// @notice 💎 Diamond Hands: community token. Buying the dip is the cheapest and highest-scoring trade.
    function diamondHands() internal pure returns (ChartHealthHook.Config memory) {
        return ChartHealthHook.Config({
            candlePeriod: 4 hours,
            minRangeTicks: 1_500, // ~16%
            zoneBps: 2_500,
            neutralFee: 5_000, // 0.5%
            topBuyFee: 3_000, // 0.3%
            bottomBuyFee: 1_000, // 0.1%
            topSellFee: 10_000, // 1%
            bottomSellFee: 50_000, // 5%
            topBuyWeight: 1,
            bottomBuyWeight: 2,
            topSellWeight: -2,
            bottomSellWeight: -3,
            maxDiscountBps: 5_000, // 50% off
            scoreHalfLife: 14 days,
            fullDiscountScore: 10 ether
        });
    }

    /// @notice 🛡️ Launch Shield: fresh launches. Wide zones, a 10% bottom-sell fee, early supporters trade free.
    function launchShield() internal pure returns (ChartHealthHook.Config memory) {
        return ChartHealthHook.Config({
            candlePeriod: 5 minutes,
            minRangeTicks: 700, // ~7%
            zoneBps: 3_000, // top and bottom 30%
            neutralFee: 10_000, // 1%
            topBuyFee: 5_000, // 0.5%
            bottomBuyFee: 3_000, // 0.3%
            topSellFee: 50_000, // 5%
            bottomSellFee: 100_000, // 10%
            topBuyWeight: 1,
            bottomBuyWeight: 1,
            topSellWeight: -2,
            bottomSellWeight: -2,
            maxDiscountBps: 10_000, // 100% off
            scoreHalfLife: 7 days,
            fullDiscountScore: 1 ether
        });
    }
}
