# Tributary

**Self-repaying validator credit.** A non-custodial marketplace where
proof-of-stake validators borrow stablecoins against their reward stream, and
each epoch's rewards repay the loan automatically — so operators cover fixed
costs without selling the tokens they'd rather keep compounding.

Contracts hold the funds. Code enforces the terms. Tributary is the venue,
**never the bank**.

- Public design: https://cashlab.network/validator-credit (migrating to
  Tributary's own domain)
- v1 target: Flare Coston2 testnet — fixed-FLR flavor first

## Status (2026-08-27)

v1 core is BUILT and fork-proven. `LoanVault` + per-loan `MarginEscrow`
(delegation-back) + `PassLedgerOracle` (underwriting, floating pass-rate,
dead-streak trigger) + per-loan `RewardCollector` (wrap + sweep). 51 passing
tests including every inherited Debt DAO failure case. Full life-of-a-loan
executed against the REAL WNat on a Coston2 fork (offer → underwrite → draw →
4 reward sweeps with interest → Repaid; conservation exact on independent
cast verification; `script/Demo.s.sol`). Real-testnet deployment
(`script/TestnetDemo.s.sol`) is rehearsed and one faucet drip away.

Still ahead (see SPEC-V1.md): real claim-routing enrollment tooling
(ClaimSetupManager/ValidatorRewardManager setter checker), keeper automation
fed from the published ledger files, fixed-dollar flavor (FTSO), independent
review, and — before any user funds — entity, counsel, professional audit.

`SPEC-V1.md` is the build spec; `FOUNDATIONS-FROM-DEBTDAO-AUDIT.md` is the
security rulebook every contract must satisfy.

## Repo rules

1. Every security rule in `FOUNDATIONS-FROM-DEBTDAO-AUDIT.md` maps to at least
   one test. A rule without its failing case is not implemented.
2. Each check ships with its failing test in the same commit.
3. No user funds touch anything before: entity, counsel, professional audit.
4. This repo is private until Milestone 1 completes.

## Toolchain

Foundry (`forge build`, `forge test`). Solidity, fixed pragma.
