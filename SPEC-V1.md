# Tributary v1 — Contract Spec (fixed-FLR flavor first)

> **STATUS NOTE (2026-08-27, later same day):** the code has moved well past
> this original v1 spec. Now built: BOTH flavors (fixed-FLR + fixed-dollar),
> the trustless Merkle-proof oracle lane, maturity default, lender-position
> transfer, keeper redundancy, and all four independent-security-review fixes.
> **`HOW-IT-WORKS.md` is the current living document; `WALKTHROUGH.md` is the
> guided tour; `DEPLOYMENTS.md` has the live addresses.** This file is kept as
> the original build record.

*Derived 2026-08-27 from the verified public design
(PITCH-VALIDATOR-CREDIT v1.1) and the Debt DAO audit rulebook. Coston2 first.
This spec is the source of truth for v1 code; change the spec before changing
the code.*

## What v1 is, honestly

A **margin-backed loan whose normal path is self-repayment** from routed
validator rewards. The reward pledge is not binding on plain wallets (owner
can always self-claim — cured in v2 by claim-binding accounts); diverting the
stream only halts amortization and walks the borrower toward margin
settlement. Underwriting inputs (trailing rewards, pass count) are supplied by
an oracle role in v1 — posted from the public ledger files, verifiable by
anyone against published data — and become trust-minimized later.

## Contracts

```
LoanVault        — loan lifecycle + accounting (the core)
MarginEscrow     — ONE PER LOAN, deployed by the vault at margin posting;
                   holds that loan's WFLR and delegates 100% of its own
                   balance back to the borrower (WNat delegation is
                   account-wide, so a shared escrow cannot delegate per-loan —
                   this is why escrows are per-loan instances)
PassLedgerOracle — posts (epoch, trailingRewards, passCount, aliveBit) per borrower
RewardCollector  — receives routed reward claims; keeper-triggered sweep into LoanVault
```

Origination pricing note: in the fixed-FLR flavor the offer states BOTH
`principalUsd` (USDT0 advanced) and `debtFlr` (FLR owed) — the consented pair
IS the locked forward price, so origination needs no FTSO read. The FTSO
enters only for the fixed-dollar flavor and for settlement valuation.

Interest accrual lands with the PassLedgerOracle step (rate reprices per
posted epoch); until then `outstanding = debtFlr` and tests cover principal
flows only. On-chain dual-cap enforcement against posted trailing rewards
also lands with the oracle step; before it, `requiredMargin` and terms are
consented off-chain by both parties.

Asset allowlist v1: **WFLR only** (margin) + **WFLR repayment** (fixed-FLR
flavor: FLR in, FLR owed — no swaps, no oracle needed on the repay path).
USDT0 principal enters at draw and is lender-supplied. stXRP margin is
**deferred** until its rebasing behavior is verified (M-09 rule).

## Loan state machine

```
OPEN(consented) → DRAWN → [REPAYING …] → REPAID → CLOSED
                     └→ TRIGGERED(dead-stream/covenant) → GRACE(7d) → SETTLED
```

- Loans keyed by immutable `loanId` in a mapping. No arrays, no positional
  invariants (H-01/H-05).
- Every external lifecycle call: `loanExists(id)` + explicit legal-state check,
  then effects, then interactions (H-04).
- Every state has a test proving the loan can still reach SETTLED or CLOSED
  from it (no unliquidatable-loan states).

## Terms (fixed at origination, from the public design)

- Line: `min(70% × trailingRewards × term, 50% × marginValue)` — trailing,
  never projected. Values snapshotted at origination.
- Rate: `benchmark + 4pts − 1pt × passCount`, floor `benchmark + 1pt`;
  reprices per 3.5-day epoch from posted pass count. Benchmark for fixed-FLR =
  staking yield (posted as a parameter with its derivation, v1).
- Debt is a fixed FLR amount (principal FLR-equivalent at origination FTSO
  price + accrued interest in FLR).
- Default trigger: `aliveBit == 0` for 4 consecutive posted epochs AND no
  payment/top-up in that window → GRACE(7 days) → settlement.
- Settlement takes exactly `outstanding + accrued + fixed default fee`; every
  remaining margin token returns to the borrower (settlement-only seizure).

## Repayment path (the load-bearing loop)

1. Keeper triggers claim: borrower's rewards land in RewardCollector
   (borrower has set claim executor + allowed recipient on ClaimSetupManager
   and ValidatorRewardManager to the collector — 4 setter calls; enrollment
   tooling must preserve existing executors; CSM setter is payable).
2. Collector sweeps to LoanVault; accounting is **balance-delta**, never
   spot-stored amounts (M-09).
3. Applied amount = `min(delta, outstanding)`; excess is credited to the
   borrower's withdrawable balance — never subtracted unchecked (H-06).
4. Lender receives repaid FLR via **pull-withdrawal** only (M-11).
5. Collector routes only to the loan's registered lender/borrower pair;
   anything unregistered reverts — no default-split fallbacks (H-02).

## Standing rules (from FOUNDATIONS — enforced in review + tests)

- CEI + `nonReentrant` on every state-changing external entry.
- Asset allowlist; no arbitrary tokens (kills hook-reentrancy class).
- No native FLR into contract functions; WFLR only.
- Consent handshakes carry no value; funds move only in body-executing calls
  (H-03).
- Every stored authorization is revocable and scoped: time-boxed, single-use,
  or invalidated when its arguments change (M-02).
- No in-protocol swaps, ever. Fixed-dollar flavor (later) prices via FTSO,
  never caller-supplied trade data (M-04).
- Hygiene defaults: fixed pragma, custom errors, zero-address checks,
  immutables, SPDX, NatSpec, `nonReentrant` first in modifier order.

## Build order

1. `LoanVault` skeleton: state machine + id-keyed storage + custom errors +
   the bogus-id/illegal-state failing tests.
2. Terms math (line sizing, pass-rate) as a pure library + fuzz tests
   (incl. underflow/cap fuzzing on repayment application).
3. `MarginEscrow` (WFLR, delegation-back, pull-withdrawals).
4. `PassLedgerOracle` (posting + 4-dead-epoch trigger logic).
5. `RewardCollector` + keeper flow (balance-delta sweep, registered-pair-only
   routing).
6. Lifecycle integration tests: full happy path; diverted-stream path;
   dead-validator settlement; over-repayment epoch; every adversarial case
   from the rulebook (borrower attacks lender, lender attacks borrower —
   treat each as the other's adversary at every transition).
7. Coston2 deploy scripts + a read-only enrollment checker (verifies a
   borrower's 4 setter calls without ever holding keys).

## Out of scope for v1 (explicitly)

Fixed-dollar flavor (needs FTSO repay-path pricing — M3), stXRP margin (until
rebasing verified), Firelight cover, claim-binding accounts (v2), P-chain
anything (v3), non-Flare chains (v4), any mainnet deployment (gated on entity
+ counsel + professional audit).
