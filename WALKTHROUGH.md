# Tributary — the guided walkthrough
### A step-by-step tour we can do together. Each step: what to look at, the one command or click that proves it, and what it means. 2026-08-27.

Open two things side by side:
- **The app** — `python3 -m http.server 8777 --directory app`, then http://localhost:8777
- **This file**, and the plain-language companion `HOW-IT-WORKS.md`.

Everything is Coston2 testnet, throwaway keys, faucet tokens. No real value.
Live v3 vault: `0x8Ad5f9654de710426985Ddc0696Fa2663D3c2Fe4`.

---

## Step 1 — "It's really on a real chain"

**Look:** the app's top bar — Coston2 connected, a live epoch number, a live
FLR/USD price, the current block.

**Prove it yourself:**
```bash
cast call 0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52 "getCurrentRewardEpochId()(uint24)" --rpc-url https://coston2-api.flare.network/ext/C/rpc
```
**Means:** the page isn't a mockup — it reads the same chain that command does.

---

## Step 2 — "The vault has rules, and they're on-chain, not in a slide"

**Look:** the "v3 vault" stat grid — min history, default trigger, grace
window, price band, epoch length. These are the deployment's own config.

**Prove it:**
```bash
cast call 0x8Ad5f9654de710426985Ddc0696Fa2663D3c2Fe4 "deadEpochsToTrigger()(uint32)" --rpc-url https://coston2-api.flare.network/ext/C/rpc
```
**Means:** policy is consciously set per chain (that's gap G10, fixed) — a
6-hour Coston2 epoch is a different world from a 3.5-day mainnet one, and the
contract knows which it's on.

---

## Step 3 — "A whole loan actually happened"

**Look:** the loan card — Loan #1, REPAID, fixed-dollar, $0.05, 100% repaid,
with borrower / lender / mailbox links to the explorer.

**Prove it:**
```bash
cast call 0x8Ad5f9654de710426985Ddc0696Fa2663D3c2Fe4 "statusOf(uint256)(uint8)" 1 --rpc-url https://coston2-api.flare.network/ext/C/rpc
```
(6 = Repaid.) **Means:** the fixed-dollar flavor isn't a diagram — a borrower
took $0.05 of real USDT0 and repaid it in FLR valued by the real oracle, and
the lender ended with exactly $0.05 of FLR. Read `DEPLOYMENTS.md` for the
wei-exact numbers.

---

## Step 4 — "The credit score is the chain's own report card"

**Look:** the pass-ledger lookup (prefilled with loan #1's borrower). Passes
held, settled epochs, trailing reward, the rate it implies.

**Code:** `src/PassLedgerOracle.sol` — the trusted `post()` lane, and now the
trustless `postWithProof()` lane (G1): it verifies a Flare reward claim against
the Merkle root Flare's FlareSystemsManager signed. See
`research/MERKLE-ORACLE-RESEARCH.md` for the real-mainnet-root proof.

**Means:** underwriting is data, not a phone call — and for the reward number,
soon-to-be un-fakeable.

---

## Step 5 — "Try the math yourself"

**Do:** the loan designer. Change passes, trailing rewards, term, margin.
Watch the credit line, the rate, and the repayment schedule move.

**Code:** the JS mirrors `src/TermsLib.sol` line for line — same 70%/50% dual
cap, same benchmark+4−1/pass rate, same per-epoch interest. Flip flavor to
fixed-dollar and the line re-values at the live price.

**Means:** every number in the product comes from these three formulas, and
you can audit them by playing.

---

## Step 6 — "What happens when it goes wrong" (the code tour)

Open `src/LoanVault.sol` and walk the state machine:
`Offered → Open → Drawn → Repaid`, with `→ Grace → Settled` for defaults.

- **No liquidation price exists.** A bad epoch only extends the payoff date.
- **Two ways to default, both fixed by the security review:**
  - the validator is genuinely dead (4 dead epochs), OR
  - the loan is still owing at **maturity** (`trip()` — this was the HIGH-1
    fix; a live-but-non-paying borrower can't hold the loan forever).
- **Settlement takes exactly debt + fee; the rest returns to the borrower.**
  Recovery, never a jackpot — so nobody profits from a borrower failing.

**Means:** the adversarial edges are handled in code, and where they weren't,
an independent review caught them (see the Security-review section of
`HOW-IT-WORKS.md`).

---

## Step 7 — "The v2 vow" (why a borrower can't cheat)

**Code:** `src/BorrowerAccount.sol`. While bound to a loan it physically can't
move value anywhere but the loan's mailbox — verified live on Coston2 by an
`eth_call` that reverts `BindingForbidsThis` (DEPLOYMENTS.md, v2 exhibit).
The MEDIUM-1/2 review fixes: it now verifies the real collector and revokes
standing approvals at bind.

**Means:** the honest v1 weakness ("a borrower could self-claim around the
vault") is closed with our own Solidity — no Flare change required.

---

## Step 8 — "What's real vs what's next" (the honest part)

Open the gaps register (`HOW-IT-WORKS.md` bottom, or the artifact). Nine of
thirteen closed; every security finding fixed. What's left is the honest hard
part:
- a **professional human audit** (the gate before any real value),
- the **first real reward claim** (armed; fires Friday when the root signs),
- a **funded v4 redeploy** carrying every fix (needs faucet gas),
- and the lender-facing extras (position transfer is now in — G11; syndication
  and wallet-write in the app are next).

**Means:** you can see exactly how far this is from "product," and it's not
hidden.

---

## The one-line version for anyone who asks
"A validator borrows dollars against rewards it hasn't earned yet; each payday
repays the loan automatically; the chain's own performance record is the credit
score; and it's live on Flare's testnet with a working app, an independent
security review, and every number provable by hand."
