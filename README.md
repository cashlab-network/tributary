# Tributary

**Self-repaying validator credit.** A non-custodial marketplace where
proof-of-stake validators borrow stablecoins against their reward stream, and
each epoch's rewards repay the loan automatically — so operators cover fixed
costs without selling the tokens they'd rather keep compounding.

Contracts hold the funds. Code enforces the terms. Tributary is the venue,
**never the bank**.

- Public design: https://cashlab.network/validator-credit
- Live on: Flare **Coston2 testnet** (throwaway keys, faucet tokens, no real value)

---

## Status (2026-08-27)

Both loan types built and live on Coston2. **118 tests** (114 local + 4
Coston2 fork-integration against the real WNat + FtsoV2). **Three independent
adversarial AI red-team rounds** — High/Medium findings fixed, low-severity
residuals documented. Not yet audited by a professional human — that is the
gate before any real value.

**Contracts** (`src/`):
- `LoanVault` — loan lifecycle, both loan types (fixed-FLR / fixed-dollar), the
  dual-cap credit line, floating pass-rate interest, maturity + dead-stream
  defaults, settlement-only seizure, lender-position transfer.
- `PassLedgerOracle` — trusted `post()` lane (pass counts, liveness) **and** a
  trustless `postWithProof()` lane that verifies rewards against the Merkle
  root Flare's FlareSystemsManager signs on-chain. Keeper redundancy via
  backup posters.
- `MarginEscrow` — per-loan WFLR collateral, delegated back to the borrower,
  self-enrolling its own reward claims.
- `RewardCollector` — per-loan reward mailbox; wraps and routes to the loan.
- `BorrowerAccount` — the v2 claim-binding account: bound to a loan it can move
  value only to that loan's collector.

## Read this in order

| Doc | What it is |
|---|---|
| `HOW-IT-WORKS.md` | Plain-language, layer-by-layer explainer + the gaps register (the honest what's-wrong list) |
| `WALKTHROUGH.md` | 8-step guided tour: a view, a verified command, and the meaning per step |
| `TOMORROW-SESSION.md` | Turnkey plan for a live self-lending test |
| `SELF-LEND-RUNBOOK.md` | Drive a real-flow loan yourself on testnet |
| `DEPLOYMENTS.md` | Every live Coston2 address + the wei-exact numbers |
| `FOUNDATIONS-FROM-DEBTDAO-AUDIT.md` | The security rulebook every contract satisfies |
| `SPEC-V1.md` | Original v1 build spec (historical; see the header note) |
| `research/` | Sourced deep-dives: Merkle oracle, real-claim runbook, P-chain multisig bond |

## Run the tests

```bash
forge test                              # 118 tests
forge test --match-contract ForkIntegration   # against real Coston2 (needs the coston2 RPC alias)
```

## The app (live testnet dApp)

`app/` is a zero-backend dApp: live Coston2 reads (vault policy, every loan,
the pass ledger, the reward Merkle roots) + a loan designer that runs the exact
TermsLib math against the live FtsoV2 price + a wallet-connect **Repay** action.

```bash
python3 -m http.server 8777 --directory app   # then open http://localhost:8777
```

`app/ethers.umd.min.js` is vendored (gitignored); re-fetch from
cdn.jsdelivr.net/npm/ethers@6 if missing.

## Drive a real loan yourself (testnet)

See `SELF-LEND-RUNBOOK.md`. One wallet plays both lender and borrower:

```bash
SELF_PK=0x<throwaway-testnet-key> forge script script/SelfLend.s.sol \
  --rpc-url coston2 --broadcast --gas-estimate-multiplier 300 --slow
```

## Non-negotiable rules

1. Every rule in `FOUNDATIONS-FROM-DEBTDAO-AUDIT.md` maps to at least one test;
   a check ships with its failing case in the same commit.
2. **No user funds before entity + counsel + professional audit.** Three
   independent AI red-team reviews are not that audit.
3. Tributary is a separate venture from the CashLab validator — its own entity,
   brand, repo. The validator's operations always preempt.
