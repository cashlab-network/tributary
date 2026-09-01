# Tributary deployments

## Test coverage (reproducible: `forge test`)

133 automated tests, 0 failing. Three layers:

- **Unit** — every LoanVault / oracle / escrow / terms path, including the
  adversarial-review regressions (each fix ships with the failing case).
- **Scenario + fuzz** (`test/Scenarios.t.sol`) — the full loan lifecycle run at
  volume, asserting **wei-exact conservation of the lender and borrower balance
  deltas** on *every* loan (the credited amounts are pinned to the exact debt /
  margin / debt+fee the contract should pay; a mispayment flips them):
  - ~80 (exactly 79) deterministic loans across a matrix of sizes × terms
    (2–16 epochs) × paths: full repay, partial-then-full, interest accrual,
    maturity default → settle, dead-stream default → settle, and lender-position
    transfer mid-loan.
  - Two fuzz invariants — `testFuzz_fullLifecycle_conserves` and
    `testFuzz_deadStreamDefault_neverJackpot` — that repay/settle randomized
    loans (size, term, epochs elapsed) and check the delta conservation, plus
    that a default credits the lender exactly debt+fee. **10,000 randomized
    loans** (`FOUNDRY_FUZZ_RUNS=5000`, 2 invariants) pass with zero
    counterexamples; 256/run (512 loans) in CI by default.
  - The collateral-shortfall cap (`due > margin` → settlement takes only the
    margin) has its own dedicated unit test (`test_settle_shortfallCapsAtMargin`
    in `LoanVault.t.sol`); zero-residual / no-stuck-funds is verified in base
    unit tests and on-chain (see the v1 exhibit "vault + escrow residuals 0"),
    not across the volume suite.
- **Fork integration** (`test/ForkIntegration.t.sol`) — 4 tests running loans
  against **real Coston2 WNat + FtsoV2** state (fixed-FLR full circle,
  fixed-dollar priced by the real FTSO, default + lender transfer, self-lend).

Plus the live on-chain exhibits below: both loan types completed end-to-end on
public Coston2, and a claim-bound account enforced on Flare's real
ClaimSetupManager executor path.

## Coston2 (chain 114) — 2026-08-27 — v1 demo, LIVE

First full life-of-a-loan executed on the public testnet: offered,
underwritten against posted ledger data, drawn, self-repaid over 4 reward
sweeps with floating pass-rate interest, margin auto-released. Loan 1 status:
Repaid (6). Verified by independent cast reads + explorer.

| Contract | Address |
|---|---|
| LoanVault | `0x99DcAB3A07681f40fc10B7E39B80B47B83c1107C` |
| PassLedgerOracle | `0xf941978Af75d17B7c5d4574CC04a4e07CE92D0B0` |
| MarginEscrow (loan 1) | `0x59c420D2c99d866D99c6c9DD360b7ED87bd689c5` |
| RewardCollector (loan 1) | `0xBeB8243A899F40dCA3FfeB36Ade263b6a0463a03` |
| Mock USD (demo stablecoin) | see broadcast/TestnetDemo.s.sol/114/run-latest.json |

Chain contracts used (read from FlareContractRegistry, never hardcoded blind):

| Contract | Address |
|---|---|
| WNat (WC2FLR) | `0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273` |
| USDT0 test (faucet) | `0xC1a5b41512496b80903d1F32d6dEa3a73212e71F` (6 decimals) |
| FXRP test (faucet) | `0x0B6a3645C240605887a5532109323a3E12273dc7` (6 decimals) |

Actor addresses (THROWAWAY testnet keys, .env, never reused for value):
deployer/lender/keeper `0xadC5dDB878FfEb396256e5F56900cf44931FE92B`,
borrower `0xB428fdb8fd187eeabeF1De68c136995AD576577e`.

Explorer: https://coston2-explorer.flare.network/address/0x99DcAB3A07681f40fc10B7E39B80B47B83c1107C

Final verified numbers (wei-exact conservation): lender received
10.012673430204032880 WFLR (10 principal + 0.01267... interest at 600 bps —
3/3 passes = benchmark 500 + floor spread 100); borrower received
21.987326569795967120 WFLR (20 margin returned + 1.98732... change from the
final sweep's excess); vault + escrow residuals 0.

## Coston2 — 2026-08-27 — v2 demo (claim-bound account, real USDT0), LIVE

Loan 1 on vault2 is deliberately left OPEN as the standing exhibit: Drawn,
partially self-repaid (outstanding ~7.0058 FLR of 10 + interest), borrower is
a claim-BOUND BorrowerAccount holding the 5 real USDT0 it borrowed. The
account is enrolled on Flare's REAL ClaimSetupManager (executor = keeper,
sole allowed recipient = the loan's collector). Fence verified on-chain by
eth_call: an owner drain attempt reverts BindingForbidsThis (0x13bb4167);
routeToCollector callable by anyone.

| Contract | Address |
|---|---|
| BorrowerAccount (bound) | `0x84e102D275E5b0F95EA8BdCF5228f42292847FF8` |
| LoanVault v2 (real USDT0) | `0x3C0Ce173dd01b802973f52260Cf2eF63397E8eBb` |
| RewardCollector (loan 1) | `0xbA1037c521859Afab57dE0114ff7E27F8fFf2bd3` |
| PassLedgerOracle | reused: `0xf941978Af75d17B7c5d4574CC04a4e07CE92D0B0` |
| ClaimSetupManager (Flare's) | `0x5Ddb590530EF66775E6225671eaBD94959e9AE0e` |
| FtsoV2 (Flare's; FLR/USD read verified free/fresh) | `0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d` |

FLR/USD feed id (verified live): `0x01464c522f55534400000000000000000000000000`.

## Coston2 — 2026-08-27 — v3 (two loan types, both fixes, real epoch ids) — earlier exhibit

Carries both same-day fixes (chain-read epoch duration
21,600s; escrow claim self-enrollment), per-chain policy config, the ±25%
price band, and the **first fixed-dollar loan**: $0.05 borrowed in real
USDT0, repaid in FLR valued by the REAL FtsoV2 — lender received
7.462608599611645849 WFLR = exactly $0.05 at the live price; borrower kept
the borrowed dollars and all upside; conservation wei-exact (7.4626 applied
+ 0.5374 change = 8 FLR delivered). Ledger posted under the REAL reward
epoch id (5992). Loan 1: REPAID.

| Contract | Address |
|---|---|
| LoanVault v3 (two loan types) | `0x8Ad5f9654de710426985Ddc0696Fa2663D3c2Fe4` |
| PassLedgerOracle v3 | `0x0a124dfA88Bd463354B4C4D2E50C5F91FdAA165F` |
| RewardCollector (loan 1) | `0x25069B8A2C525457d6512870790a11f6eDEa720d` |

Ops note: Coston2 gas ~650–1200 gwei — a full scripted run costs whole FLR,
and `--gas-estimate-multiplier 300` can price single txs over 2 FLR. Keep
the deployer topped up; finish interrupted runs with plain `cast send`
(explicit `--gas-price` + `--priority-gas-price`).

Real delegation live since 2026-08-27: borrower EOA WFLR → provider
delegation address `0x07f5053C867AE107Db15A38Aa4421b2c24aC4e51`; an epoch
watcher wakes the session at epoch 5994 for the first REAL executor claim.

## Coston2 — 2026-08-28 — v4 (self-lend, security-fixed) — CURRENT, the app points here

The vault `app/app.js` reads. A full self-lending loan (one wallet plays both
lender and borrower) run end-to-end on 2026-08-28: loan 1 offer → draw →
Repaid, verified on-chain. Carries the post-review security fixes.

| Contract | Address |
|---|---|
| LoanVault v4 (self-lend) | `0xe7ec100ea45af3586052E435006B983343dcd550` |
| PassLedgerOracle v4 | `0x444D6680107F9F0D5d08F07e73e1A4028c74a614` |

**Source is ahead of every live deployment (read this before checking a live
vault against `src/`).** The current `src/` adds the Tier-A staked door
(`offerStaked`, reads PChainStakeMirror), the everyday-holder stream door
(`offerStream`), and the rebuilt trustless trailing oracle (review-4/5) — all
covered by the unit + Coston2 fork test suites, but NOT yet redeployed. A funded
redeploy carrying every fix follows the professional audit. So: the live
exhibits above prove the core loan lifecycle on-chain; the newest features are
proven by tests, pending the audit gate.

