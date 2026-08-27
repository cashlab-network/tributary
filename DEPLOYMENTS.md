# Tributary deployments

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

Next deploy should use real faucet USDT0 (`0xC1a5...71F`) instead of the mock.
