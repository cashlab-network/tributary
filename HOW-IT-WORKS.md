# Tributary, explained from the ground up
### What we built, how it works, how it was tested, what actually happened on-chain — and every gap we know about. 2026-08-27.

*Written plainly on purpose. The gaps register at the end is the part to
argue with.*

---

## The idea in one breath

A validator earns coins every few days but pays its bills in dollars. Today
its only move is selling coins. Tributary lets it **borrow dollars against
the coins it hasn't earned yet** — and then every payday, the paycheck goes
straight to the lender until the loan is gone. Nobody holds anyone's money on
trust: a contract holds it, and the code is the loan agreement.

Think of it as an **advance on your paycheck, where your employer pays your
lender directly** — except the "employer" is the Flare network itself, and
your credit score is your public uptime record.

## The cast of characters

| Who | What they are | In our live demo |
|---|---|---|
| **Borrower** | A validator with a reward stream | A test account we control |
| **Lender** | Someone with dollars who wants FLR yield | Another test account |
| **LoanVault** | The deal table + rulebook. Holds the dollars, tracks the debt, enforces every rule | Deployed on Coston2 |
| **MarginEscrow** | A safety-deposit box holding the borrower's collateral — one box per loan | Deployed per loan |
| **RewardCollector** | The loan's mailbox — where the paycheck lands | Deployed per loan |
| **PassLedgerOracle** | The scoreboard clerk — posts each validator's public performance record on-chain | Deployed on Coston2 |
| **Keeper** | A cron job. Pushes the paycheck along each epoch, posts the scoreboard | Our script |
| **BorrowerAccount** (v2) | The vow — a wallet that physically can't cheat while a loan is open | Deployed + bound on Coston2 |

## Layer by layer

### Layer 0 — what Flare already gives us (we built none of this)

1. **A paycheck schedule.** Every validator/provider earns rewards every
   "reward epoch" (3.5 days on mainnet; **6 hours on Coston2** — Daman
   caught that; it's now read from the chain, never assumed).
2. **A public report card.** Every 3.5 days Flare publishes who passed, who
   got strikes, who earned what. Nobody can fake it.
3. **Payment routing switches.** A wallet can name who's allowed to collect
   its rewards and where they're allowed to land (`setClaimExecutors` /
   `setAllowedClaimRecipients` on the ClaimSetupManager). Built into Flare.
4. **A price oracle.** FTSOv2 tells any contract the FLR/USD price for free.

### Layer 1 — TermsLib, the calculator

Pure math, no money. Three formulas, straight from the public design:

- **How much can you borrow?** The SMALLER of: 70% of what your stream
  actually earned recently (× the loan term), or 50% of the collateral you
  post. Trailing earnings only — never projections (that rule is written in
  the miner-lending graveyard).
- **What's your rate?** Your lender's passive alternative (e.g. staking
  yield) **+ 4 points, minus 1 point per pass you hold**, never below +1.
  Hold all 3 passes → cheapest money. Take a strike → your rate drifts up.
  The chain's own incentive system IS the credit spread.
- **What if you overpay?** The payment is capped at what you owe BEFORE
  subtracting; extra is change back. (Debt DAO's worst bug was exactly this
  subtraction underflowing. Ours can't, and a fuzz test throws thousands of
  random numbers at it to prove it.)

### Layer 2 — PassLedgerOracle, the scoreboard clerk

Each epoch, a "poster" writes each borrower's row on-chain: trailing
earnings, passes held, epochs settled, and whether the stream was alive.
Rows only ever append, epochs only move forward. Everything posted is
checkable by anyone against Flare's published files — **but in v1 the clerk
is trusted to copy them honestly. That's gap #1 in the register.**

### Layer 3 — LoanVault, the deal table

A loan walks through named rooms, and every door checks your ID:

```
Offered → Open → Drawn → Repaid → done
                    ↘ Grace (7 days) → Settled
```

- **Offered:** the lender writes exact terms for ONE named borrower: dollars
  advanced, FLR owed (this pair IS the locked forward price — no oracle
  needed), collateral required, default fee. No money moves. Revocable.
- **Open (= the underwriting moment):** the borrower accepts — and the
  contract refuses unless the scoreboard says: 10+ epochs of history, stream
  currently alive, and the ask fits under BOTH caps. The borrower's consent
  and the credit check happen in the same breath.
- Lender's dollars come in; borrower's collateral goes into its own escrow
  box; borrower **draws** the dollars. Zero coins sold anywhere.
- **Repaying:** every epoch the mailbox forwards the paycheck; the vault
  applies it to the debt and books it for the lender (who pulls it out
  themselves — the vault never pushes money at anyone; a hostile receiver
  can't jam the machine).
- **No liquidation price exists in the code.** A bad epoch does nothing but
  extend the payoff date. The ONLY trigger: the scoreboard shows the stream
  **dead 4 epochs in a row** → a 7-day grace clock starts → ANY payment
  cures it → if it expires uncured, settlement takes **exactly** debt +
  interest + the pre-agreed fee from the collateral, and every remaining
  token goes back to the borrower. Recovery, never a jackpot — so nobody on
  earth profits from making a borrower fail.

### Layer 4 — MarginEscrow, the safety-deposit box that keeps working

The collateral doesn't sit dead: each loan's box delegates 100% of its vote
power back to the borrower, so their network weight doesn't drop while
pledged. (Found today: the box also EARNS delegation rewards it couldn't
claim — they'd have expired. Now every box registers its claims at birth:
keeper executes, borrower is the only allowed recipient.)

### Layer 5 — RewardCollector, the mailbox

One per loan. Rewards land (native FLR or wrapped), anyone can hit "sweep":
it wraps and forwards the whole balance — to the vault as repayment while
the loan lives, back to the borrower once it's over. It can't send anywhere
else; an unregistered destination is impossible, not just forbidden.

### Layer 6 — BorrowerAccount, the vow (v2 — needed no Flare changes)

v1's honest weakness: Flare always lets a wallet claim its own rewards, so a
borrower could quietly claim around the mailbox (only hurting themselves —
that stops repayment and marches toward settlement — but still). v2 closes
it: the borrower's reward identity becomes a small contract wallet.
**Unbound, it's simply their wallet. Bound to a loan, it physically cannot
move value anywhere except the loan's mailbox** — no transfers, no
approvals, no re-pointing of claim settings (its escape hatch only reaches
an allowlist frozen at bind time, which the lender sees before funding). The
moment the vault says the loan is over, anyone can release it — the borrower
never needs the lender's permission to get their wallet back, and vice versa
while debt is owed.

## What actually happened on-chain (the play-by-play)

**Loan 1 — the full circle (Coston2, 2026-08-27).** Lender offered 1,000
test-USD against a debt of 1,000 FLR, 2,000 WFLR collateral, 4-epoch term.
Underwritten at accept against a posted 3-pass record. Drawn. Then four
"paydays" of 300 FLR each hit the mailbox:

| Sweep | Debt before | Interest that epoch | Payment | Debt after |
|---|---|---|---|---|
| 1 | 1000.000 | +0.575 | −300 | 700.575 |
| 2 | 700.575 | +0.403 | −300 | 400.978 |
| 3 | 400.978 | +0.231 | −300 | 101.209 |
| 4 | 101.209 | +0.058 | −300 | **0 — REPAID** |

Lender walked away with 1,001.267 FLR (principal + interest, at the 3-pass
floor rate). Borrower got all 2,000 collateral back plus 198.733 change from
the final overpayment. Vault and escrow ended at exactly zero. Paid in +
paid out balanced **to the wei**.

**Loan 2 — the bound account, left running as the standing exhibit.** A
BorrowerAccount borrowed **5 real faucet USDT0** (not our mock). It enrolled
on Flare's REAL ClaimSetupManager — our keeper as executor, the loan's
mailbox as the only allowed destination — then bound itself. One payday
swept; ~7.006 FLR still owed; the account still holds its borrowed dollars.
We then asked the chain: "if the owner tries to pull coins out of the bound
account, what happens?" The chain answered: **reverts, `BindingForbidsThis`.**

## How it was tested (and what testing can't claim)

- **67 automated tests**, including one test per inherited Debt DAO audit
  failure ("close a loan that doesn't exist", "overpay past zero", "pay with
  a token that delivers less than sent" — each must fail safely).
- **Fuzz tests**: the machine throws thousands of random values at the money
  math and asserts things that must NEVER be false (credit line never
  exceeds either cap; rate never below the lender's alternative; repayment
  never underflows; nothing minted or lost).
- **Fork rehearsals**: every live run was first executed against a local
  clone of Coston2 (real WNat contract included) until it ran with zero
  errors.
- **Live runs + independent reads**: final states were confirmed by separate
  read commands against the public RPC, never by trusting the script's own
  logs.
- **What none of this proves:** all checks so far are by the same builder.
  Per our own standing rule, nothing here counts as verified until a session
  that did NOT write it tries to break it. That review hasn't happened yet.

## THE GAPS REGISTER — what's honestly wrong or missing

**G1 · The scoreboard clerk is trusted.** The oracle poster could post lies;
the contract can't tell. *Planned fix: verify posted rewards against the
Merkle roots Flare's RewardManager already stores on-chain — then lying
becomes impossible, not just detectable. Research task open.*

**G2 · The paydays were simulated.** Demo rewards were plain transfers, not
real RewardManager claims. The executor-claim path against Flare's real
reward contracts is enrolled but has never actually executed a claim. *Real
delegation is now live (borrower WFLR → active provider, 2026-08-27), so
genuinely earned rewards exist to claim within epochs. The first real
claim-and-sweep is the next milestone.*

**G3 · Demo epoch numbers were made up.** We posted epochs "100, 1000…";
Coston2 is really at ~5992. Harmless (per-borrower monotonic) but the real
keeper must post true epoch ids derived from the published files.

**G4 · The two LIVE vaults have the interest bug.** Today's fix (epoch
length read from the chain) came AFTER deployment — the live exhibits
charge 3.5-day interest on 6-hour epochs (14× overcharge). Fine as museum
pieces; **a v3 redeploy with both of today's fixes is required** and nothing
should ever be quoted off the current live vaults' interest numbers.

**G5 · Live escrows predate the reward-claim fix** — their delegation
rewards are unclaimable (exactly the bug now fixed in code). Same answer:
v3 redeploy.

**G6 · Real validators haven't enrolled anything.** The BorrowerAccount
requires the borrower to adopt it as their reward identity — real migration
friction we haven't measured; and the staking-rewards side
(ValidatorRewardManager) has its own separate lists we've read about but
never exercised. The pitch's "four setter calls" remains partially proven
(CSM: yes, live; VRM: no).

**G7 · The benchmark rate is typed in by hand.** "Staking yield" enters as a
number in the offer, not derived on-chain. A dishonest pair could consent to
a nonsense rate — fine between consenting adults, but the marketplace UI
must surface the real benchmark.

**G8 · Fixed-dollar flavor doesn't exist yet.** Only its price feed is
verified (FTSOv2 FLR/USD, free, fresh). All live loans are the fixed-FLR
flavor.

**G9 · Nobody independent has attacked this code.** 67 self-written tests
are necessary, not sufficient. Independent refutation review → then
professional audit before any real value, ever.

**G10 · Policy constants are mainnet-shaped.** 10-epoch history, 4-dead-epoch
trigger, 7-day grace: sensible at 3.5-day epochs; odd at 6-hour ones (4 dead
epochs = 1 day). These should be per-deployment policy, consciously chosen.

**G11 · One lender per loan, non-transferable.** No syndication, no selling
your position, no partial exits. Deliberate v1 scope — but it caps lender
liquidity and is the first thing sophisticated lenders will ask about.

**G12 · One keeper, no redundancy.** If our single keeper dies, sweeps and
scoreboard posts stop. (Mainnet FSP rewards expire ~90 days — a dead keeper
eventually costs real money.) Needs at least a second independent executor.

**G13 · Nothing checks the price-pair sanity.** `principalUsd` (6 decimals)
and `debtFlr` (18 decimals) are consented as a pair; the contract never
checks the implied FLR price is sane. A UI must; the contract arguably
should bound it against FTSO ± a band.

## What's next, in order

1. **v3 redeploy** with today's two fixes (G4, G5) + real epoch ids (G3).
2. **First real reward claim** through the enrolled executor path (G2) —
   delegation is already accruing.
3. **Fixed-dollar flavor** on FTSOv2 (G8), with the price-band check (G13).
4. **Merkle-proof oracle research** in flare-foundation/flare-smart-contracts-v2 (G1).
5. **Independent refutation review** of contracts + this document (G9).
6. Keeper redundancy + real-data pipeline (G12, G3), policy constants per
   chain (G10), VRM staking-side enrollment (G6).

*Everything above is testnet with throwaway keys and faucet tokens. No real
value has touched any of this, and none will before entity + counsel +
professional audit — that ordering is a standing rule, not a preference.*
