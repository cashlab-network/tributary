# Drive a real loan yourself — Coston2 self-lending runbook

**Testnet only. Testnet USDT0 from the faucet — no real money, zero risk.**
You play both lender and borrower (the vault allows one wallet to be both),
so you can watch a whole loan happen with your own hands.

This deploys a fresh **v4** vault carrying every security fix, then runs a
full loan: offer → accept → fund → margin → draw → repay. Fork-tested against
the real Coston2 WNat + FtsoV2 (`test_fork_selfLend`).

## What you need

1. **A throwaway Coston2 wallet key** (a fresh key — never a real-funds key).
   `cast wallet new` prints one, or use any testnet key.
2. **C2FLR for gas + margin.** Coston2 gas is pricey; the default loan needs
   roughly **~130 C2FLR** total (deploy + lifecycle gas + 100 FLR margin +
   repay buffer). The faucet gives 100/address/day, so claim **twice** (two
   days, or two addresses that then consolidate) — or lower `MARGIN_FLR`.
   Faucet: https://faucet.flare.network/coston2 → "Request C2FLR".
3. **Testnet USDT0 to lend.** Faucet → "Request USDT0" (gives 10). The default
   loan advances $0.30, so one claim is plenty.

Put the wallet address into the faucet for both C2FLR and USDT0.

## Run it

```bash
cd ~/tributary
SELF_PK=0x<your-throwaway-testnet-key> forge script script/SelfLend.s.sol \
  --rpc-url coston2 --broadcast --gas-estimate-multiplier 300 --slow
```

It prints the **v4 vault address**, the loan id, your USDT0 balance after the
draw, and the outstanding debt after one repayment. A live self-repaying loan
now exists on Coston2 under your control.

## Watch it in the app

Point the app at your new vault: edit `app/app.js`, set `A.vault` to the
printed v4 vault address (and `A.oracle` to the printed oracle), then:

```bash
python3 -m http.server 8777 --directory app
```

Open http://localhost:8777 — your loan shows up as a live card.

## Do more transactions

Scale the loan up (still testnet dollars):

```bash
PRINCIPAL_USD=1000000 DEBT_USD=1000000 MARGIN_FLR=400000000000000000000 \
SELF_PK=0x... forge script script/SelfLend.s.sol --rpc-url coston2 --broadcast \
  --gas-estimate-multiplier 300 --slow
```
(`MARGIN_FLR` is in wei — 400 FLR = `400e18`.)

Repay more on an existing loan (id from the run):
```bash
cast send <VAULT> "repay(uint256,uint256)" <ID> <FLR_WEI> \
  --private-key $SELF_PK --rpc-url https://coston2-api.flare.network/ext/C/rpc \
  --gas-price 1200gwei --priority-gas-price 100gwei
```

## Why not real money on mainnet yet

The mechanics here are identical to mainnet. The one thing that must come
first is a **professional security audit** — two independent AI reviews found
and fixed two fund-trapping HIGH-severity bugs *this session*, and a bug traps
funds regardless of whose they are. That audit is the gate (it's also the best
use of real budget). After it, a funded mainnet deploy with real USDT0 is the
plan, and everything here is staged for it.
