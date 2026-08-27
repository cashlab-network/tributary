// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TermsLib — pure terms math for Tributary v1
/// @notice Line sizing and the floating pass-rate, exactly as published in the
///         design (v1.1): line = min(70% x trailing rewards x term,
///         50% x margin value); rate = benchmark + 4pts - 1pt per pass held,
///         floored at benchmark + 1pt. Trailing, never projected.
library TermsLib {
    uint256 internal constant BPS = 10_000;

    /// Stream advance rate: 70% of the trailing reward stream.
    uint256 internal constant STREAM_HAIRCUT_BPS = 7_000;

    /// Margin advance rate: 50% of posted margin value.
    uint256 internal constant MARGIN_CAP_BPS = 5_000;

    /// Rate spread at zero passes: benchmark + 4 points.
    uint256 internal constant BASE_SPREAD_BPS = 400;

    /// Discount per FIP.10 pass held: 1 point.
    uint256 internal constant PASS_DISCOUNT_BPS = 100;

    /// Spread floor: benchmark + 1 point.
    uint256 internal constant MIN_SPREAD_BPS = 100;

    /// @notice Dual-cap credit line.
    /// @param trailingRewardPerEpoch trailing average reward per 3.5-day epoch
    ///        (wei), derived from PUBLISHED epochs only — never a projection
    /// @param termEpochs loan term measured in reward epochs
    /// @param marginValue value of posted margin (wei, same unit as rewards)
    /// @return line the maximum principal
    function creditLine(uint256 trailingRewardPerEpoch, uint256 termEpochs, uint256 marginValue)
        internal
        pure
        returns (uint256 line)
    {
        uint256 streamCap = (trailingRewardPerEpoch * termEpochs * STREAM_HAIRCUT_BPS) / BPS;
        uint256 marginCap = (marginValue * MARGIN_CAP_BPS) / BPS;
        line = streamCap < marginCap ? streamCap : marginCap;
    }

    /// @notice Floating pass-rate in bps: benchmark + 4pts - 1pt/pass,
    ///         floored at benchmark + 1pt. Pass counts above 3 earn no extra
    ///         discount (3/3 is the ledger maximum today; defensive clamp).
    function rateBps(uint256 benchmarkBps, uint256 passCount) internal pure returns (uint256) {
        uint256 discount = (passCount > 3 ? 3 : passCount) * PASS_DISCOUNT_BPS;
        uint256 spread = BASE_SPREAD_BPS - discount; // 400 - <=300: cannot underflow
        if (spread < MIN_SPREAD_BPS) spread = MIN_SPREAD_BPS;
        return benchmarkBps + spread;
    }

    uint256 internal constant YEAR_SECONDS = 365 days;

    /// @notice Linear interest for whole reward epochs at an ANNUALIZED rate
    ///         in bps. Epoch length is a parameter because it is a CHAIN
    ///         property read from FlareSystemsManager, never assumed:
    ///         302,400s (3.5 days) on Flare mainnet, 21,600s (6 hours) on
    ///         Coston2 — hardcoding 3.5 days overcharged testnet 14x.
    function epochInterest(uint256 outstanding, uint256 annualRateBps, uint256 epochs, uint256 epochSeconds)
        internal
        pure
        returns (uint256)
    {
        return (outstanding * annualRateBps * epochSeconds * epochs) / (BPS * YEAR_SECONDS);
    }

    /// @notice FLR wei -> USD with 6 decimals, at an FTSO feed reading
    ///         (value, decimals). Floors — value credited never exceeds
    ///         value delivered.
    function flrToUsd6(uint256 flrWei, uint256 feedValue, uint8 feedDecimals) internal pure returns (uint256) {
        return (flrWei * feedValue) / (10 ** feedDecimals * 1e12);
    }

    /// @notice USD (6 decimals) -> FLR wei at an FTSO feed reading, rounding
    ///         UP — used when converting a debt into the FLR that settles it,
    ///         so rounding never shorts the party being repaid.
    function usd6ToFlrCeil(uint256 usd6, uint256 feedValue, uint8 feedDecimals) internal pure returns (uint256) {
        uint256 num = usd6 * 10 ** feedDecimals * 1e12;
        return (num + feedValue - 1) / feedValue;
    }

    /// @notice Cap a repayment at the outstanding balance (H-06 rule: never
    ///         subtract more than the minuend; excess is change, not underflow).
    /// @return applied amount to subtract from the balance
    /// @return excess remainder credited back to the borrower
    function applyRepayment(uint256 outstanding, uint256 amount)
        internal
        pure
        returns (uint256 applied, uint256 excess)
    {
        applied = amount < outstanding ? amount : outstanding;
        excess = amount - applied;
    }
}
