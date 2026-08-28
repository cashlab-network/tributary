# Tomorrow's test session — the plan

Goal: you drive a real self-lending loan on Coston2 end to end, and we watch
it work together. Testnet USDT0, throwaway key, zero real-money risk.

---

## Before we start (do these first — they need your hands)

1. **Make a throwaway testnet key** and keep it in an env var, not a file:
   ```bash
   cast wallet new
   ```
   Copy the address and private key somewhere for the session. This key is
   TESTNET ONLY — never anything of value.

2. **Claim faucet funds to that address** at https://faucet.flare.network/coston2
   (each needs the reCAPTCHA click — that's the part I can't do):
   - **Request C2FLR** — do it **twice** if it lets you (the loan + gas needs
     ~130; the faucet gives 100/day, so a second address or a second day
     helps; or we shrink the loan with env vars — see below).
   - **Request USDT0** — once (gives 10; the default loan uses $0.30).

3. Tell me the address so I can confirm on-chain it's funded before we spend a
   thing.

---

## The main event (I'll run these with you, you hold the key)

Everything is fork-tested — it worked against the real Coston2 contracts in
`test_fork_selfLend`, so no surprises.

```bash
cd ~/tributary
SELF_PK=0x<your-testnet-key> forge script script/SelfLend.s.sol \
  --rpc-url coston2 --broadcast --gas-estimate-multiplier 300 --slow
```

What happens, live: it deploys a fresh **v4 vault** (every security fix),
posts your ledger row, then — with you as BOTH lender and borrower —
offers → accepts → funds → posts margin → draws the dollars → repays once.
It prints the vault address, your USDT0 balance after drawing, and the
outstanding debt after repayment.

If the faucet was stingy, shrink it (all env-overridable, wei for FLR):
```bash
PRINCIPAL_USD=100000 DEBT_USD=100000 MARGIN_FLR=40000000000000000000 \
SELF_PK=0x... forge script script/SelfLend.s.sol --rpc-url coston2 \
  --broadcast --gas-estimate-multiplier 300 --slow
```
(That's a $0.10 loan, 40 FLR margin.)

---

## Watch it live in the app

I'll point the app at your new vault (edit `app/app.js` `A.vault` + `A.oracle`
to the printed addresses), then:
```bash
python3 -m http.server 8777 --directory app
```
Open http://localhost:8777 — your loan is a live card, and the top bar shows
the chain. Then the fun part:

- **Connect wallet** (top-right) → approve Coston2.
- In **"Repay a loan from your wallet"**, enter the loan id and an amount
  (WFLR), hit **Repay**, and sign in your wallet. Watch the card's
  outstanding drop and the progress bar move. That's a real signed tx you did
  yourself, paying down your own loan.

---

## Things we can try together once it's live

- Repay it to **zero** and watch it flip to REPAID and release your margin.
- Run SelfLend again at a **bigger size** and see the dual cap size the line.
- Look up your address in the **pass-ledger** panel to see what you're
  underwritten on.
- Play the **loan designer** against the live price.
- (If you want to see a default) we can post dead epochs and trip → settle on
  a throwaway loan — recovery goes to the lender, the rest back to you.

---

## The map for the walkthrough

`WALKTHROUGH.md` is the 8-step tour (each step: a view, a command, what it
means). `HOW-IT-WORKS.md` is the plain-language companion with the gaps
register. We can go step by step against your own live loan.

## What stays off the table (until an audit)

Real money on mainnet. Two reviews fixed two fund-trapping HIGH bugs this
week; a professional audit is the gate, and it's the right place to spend real
budget. Everything is staged for a funded mainnet deploy the day that clears.
