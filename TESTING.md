# Testing & verification — how this code is checked

For anyone reviewing or auditing Tributary: this is what's already been done,
so you can aim your effort at what hasn't.

## The suite

`forge test` — **106 tests** across unit, fuzz, and fork-integration.

- **Unit tests** per contract (`test/*.t.sol`): every lifecycle transition,
  every access-control path, every custom error.
- **Inherited-failure tests**: one test per applicable finding from the Debt
  DAO Code4rena audit (`FOUNDATIONS-FROM-DEBTDAO-AUDIT.md`) — bogus-id calls,
  overpayment underflow, fee-on-transfer rejection, hook-reentrancy avoidance.
- **Fuzz tests** (`TermsLib.t.sol`): the money math — credit line never
  exceeds either cap, rate never below the lender's alternative, repayment
  never underflows, conservation (nothing minted or lost).
- **Merkle tests** (`MerkleOracle.t.sol`): valid/invalid/tampered/replayed
  proofs, unsigned epochs, double-prove; the leaf format matches Flare's
  `RewardManager` exactly (see `research/MERKLE-ORACLE-RESEARCH.md`, which
  re-derives a real mainnet root end to end).
- **Fork integration** (`ForkIntegration.t.sol`, `forge test --match-contract
  ForkIntegration`): both flavors, default→settle, lender transfer, and the
  single-wallet self-lend flow — all against the REAL Coston2 WNat + FtsoV2 +
  ClaimSetupManager on a live fork.

## Coverage (excluding scripts, 2026-08-27)

| Contract | Lines | Funcs |
|---|---|---|
| LoanVault | 95.6% | 95.8% |
| PassLedgerOracle | 100% | 100% |
| MarginEscrow | 100% | 100% |
| RewardCollector | 100% | 100% |
| TermsLib | 100% | 100% |
| BorrowerAccount | 93.9% | 100% |

Branch coverage is lower (~62% overall) — mostly untaken revert branches;
worth an auditor's attention. Scripts (`script/*.s.sol`) are exercised via
fork runs, not unit coverage.

## Independent adversarial reviews

Per the project rule "nothing ships on one process's word," the contracts have
been attacked by **independent sessions told to refute, not review**:

- **Review 1** (core): found 2 HIGH (unrecoverable loan; dust-cure grief) + 2
  MEDIUM (decoy collector; surviving approval). All fixed with regression
  tests.
- **Review 2** (fixes + new features): no new HIGH; 2 lower issues
  (selector-narrow approval fence; zero-collector bind) fixed.
- **Review 3** (trustless-underwriting wiring): found 1 HIGH — the "proven
  trailing" was cherry-pickable (prove only your peak epoch → 5.26x line
  inflation, demonstrated by PoC). Fixed: the proven FEE epochs must form a
  contiguous window of a minimum length, or the trailing is 0. Regression
  tests added (single-peak→0, gap→0, full-window→honest average).

These are AI reviews. **A professional human audit is still the gate before
any real value** — that is the single most important thing this suite does
NOT replace.

## What is NOT yet proven

- No mainnet deployment; no real funds anywhere.
- The trusted oracle lane (pass counts, liveness) is trust-assumed by design;
  only reward amounts have a trustless (Merkle) path.
- The first real reward claim through the executor path has not yet executed
  (armed; see `research/REAL-CLAIM-RUNBOOK.md`).
- The P-chain self-bond-collateral idea is unverified pending a Coston2
  dry-run (`research/PCHAIN-MULTISIG-BOND-RESEARCH.md`).
