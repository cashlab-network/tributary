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
   "reward epoch" (3.5 days on mainnet; **6 hours on Coston2** — caught in
   review; it's now read from the chain, never assumed).
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

**G1 · FIXED — the reward number is now trustless.** `postWithProof()` on the
oracle verifies a Flare reward claim against the Merkle root Flare's
FlareSystemsManager has signed on-chain (exact RewardClaim struct + sorted-
pair keccak, proven end-to-end against a real mainnet root in
`research/MERKLE-ORACLE-RESEARCH.md`). A lying poster is now *impossible* for
a proven FEE amount (a provider's own income); `provenTrailingFee` is a fully
trustless trailing average. Residual: FIP.10 **pass counts** have no on-chain
commitment anywhere, so they necessarily stay in the trusted-poster lane.

**G2 · Real claim armed and de-risked; execution is calendar-gated.** The
runbook (`research/REAL-CLAIM-RUNBOOK.md`) established our mid-epoch delegation
was not counted until epoch 5994; rewards become claimable ~Fri Aug 28 ~14:00
UTC. The top failure point it named — the owner-side executor + allowed-
recipient enrollment on the delegator EOA — is now **done and verified
on-chain** ahead of time. `keeper/claim_real.sh` is ready; a watcher fires the
moment epoch 5994's root is signed. Proofless weight-based claiming applies.

**G3 · FIXED same day.** The v3 stack posts under the REAL reward epoch id
read from FlareSystemsManager (5992 at deploy). Keeper discipline still
applies for future posts.

**G4 · FIXED same day — v3 is live** (`0x8Ad5…2Fe4`) with epoch duration
read from the chain. The v1/v2 vaults remain museum pieces only; never
quote interest numbers from them.

**G5 · FIXED same day** — v3 escrows self-enroll their claims at birth
(keeper executes, borrower sole recipient).

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

**G8 · FIXED same day — the fixed-dollar loan type is built and PROVEN LIVE:**
a $0.05 loan in real USDT0 repaid in FLR valued by the real FtsoV2; the
lender received exactly $0.05 worth (7.4626 WFLR at the live price),
conservation wei-exact. Borrower keeps upside by construction (tested:
price doubles, half the coins).

**G9 · One independent refutation review done — 4 real findings, all fixed.**
A separate session attacked the contracts and found two HIGH (a live-but-non-
paying borrower could hold an unrecoverable loan; a 1-wei "cure" could stall
settlement forever) and two MEDIUM (a decoy-collector bind; a pre-existing
approval surviving the fence). All four are fixed with regression tests (see
the Security-review section below). The reviewer confirmed token conservation,
the fixed-dollar rounding, and reentrancy all held. This is one adversarial AI
pass — a **professional human audit is still required before any real value**,
and remains the hard gate.

**G10 · FIXED same day** — history minimum, dead-epoch trigger, and grace
length are now per-deployment configuration, chosen consciously per chain
instead of hardcoded.

**G11 · One lender per loan, non-transferable.** No syndication, no selling
your position, no partial exits. Deliberate v1 scope — but it caps lender
liquidity and is the first thing sophisticated lenders will ask about.

**G12 · One keeper, no redundancy.** If our single keeper dies, sweeps and
scoreboard posts stop. (Mainnet FSP rewards expire ~90 days — a dead keeper
eventually costs real money.) Needs at least a second independent executor.

**G13 · FIXED same day** — fixed-FLR pairs are now sanity-checked at accept
against the FTSO within a configurable band (±25% on v3); a fat-fingered
pair reverts PriceOutOfBand. FTSO reads carry a staleness guard.

## Security review — the four findings and their fixes

An independent session was told to *refute* the contracts, not review them.

- **HIGH-1 · unrecoverable loan.** `termEpochs` sized the loan but was never a
  deadline, so a validator that stayed alive but never repaid could hold the
  principal forever with no lender lever. **Fix:** the term is now a real
  maturity — a loan still owing at `maturesAtEpoch` is a settleable default,
  alive or not. (This also corrected a false claim in this doc: diverting the
  stream walks toward settlement *via the term*, not via dead-epochs.)
- **HIGH-2 · dust-cure grief.** Any 1-wei payment during Grace reset the loan
  to Drawn, so anyone could stall settlement indefinitely. **Fix:** partial
  payments still apply but no longer reset status; only full repayment heals a
  loan in Grace, and settlement proceeds when the window expires.
- **MEDIUM-1 · decoy collector.** `BorrowerAccount.bind` trusted a caller-
  supplied collector. **Fix:** it now verifies against `vault.collectorOf(id)`.
- **MEDIUM-2 · surviving approval.** An approval granted while unbound could
  drain a later WFLR reward past the fence. **Fix:** `exec` records every
  approve; `bind` revokes them all before fencing.
- **LOW · settlement price band** is a documented residual (adding a revert to
  `settle()` would reintroduce the HIGH-1 stuck-loan class).

The reviewer could NOT break token conservation, the fixed-dollar rounding, or
reentrancy — the parts it attacked hardest.

**A SECOND independent review** then attacked the fixes and the new features
(maturity default, lender transfer, keeper redundancy, the Merkle oracle). It
found **no new HIGH** and confirmed the maturity math, grace accounting,
`transferLender`, the Merkle verification, and backup-poster access control all
held. Two lower issues, both now fixed: the approval fence caught only
`approve` (now also `increaseAllowance`/`decreaseAllowance` — F1), and `bind`
accepted a zero collector on a pre-accept loan (now rejected — F2).

**A THIRD review** attacked the trustless-underwriting wiring specifically and
found **1 HIGH**: the "proven trailing" figure was cherry-pickable — a borrower
proving only their single peak reward epoch got a credit line sized off that
peak, not their trailing income (PoC showed 5.26x inflation). This mattered
because it defeated the exact income-based underwriting the feature exists to
provide (the dual cap still limited a well-collateralized lender's exposure, so
it was never a live drain — and the feature was off by default in every vault).
Fixed: the proven epochs must form a **contiguous window** of a minimum length
or the trailing is zero, so you can't prove only your good epochs. Regression
tests cover single-peak→0, gap→0, and full-window→honest-average.

Three independent adversarial AI red-team rounds — High/Medium findings fixed,
low-severity residuals documented — but that is still not a professional human
audit, which stays the hard gate before any real value.

## A bonus finding: self-bond collateral may need no Flare change

Research (`research/PCHAIN-MULTISIG-BOND-RESEARCH.md`) found that a **new**
Flare self-bond can already name a threshold (multisig) owner for its staked-
principal return, with zero protocol changes — and because Flare pays P-chain
rewards as zero (rewards flow through the C-chain contracts we integrate),
principal control and reward economics are cleanly independent. This could
deliver "self-bond as collateral" without the v3 FIP — verdict PARTIALLY YES,
gated on a Coston2 dry-run and the report's UNVERIFIED list. No per-party
timelock primitive exists, so default resolution stays cooperative (2-of-2 or
pre-signed exit), not unilateral.

## What's next, in order

1. **First real reward claim** (G2) — armed and de-risked; fires when epoch
   5994's root signs (~Fri Aug 28).
2. **Professional audit** (G9) — the hard gate before any real value.
3. Wire `provenTrailingFee` (G1) into the vault's underwriting so the trailing
   number itself is trustless, not just provable.
4. Keeper redundancy (G12); VRM staking-side enrollment (G6); benchmark
   surfaced from chain data (G7); syndication/transferability (G11).
5. A funded v4 redeploy carrying every fix, then wallet-write in the app.

*Everything above is testnet with throwaway keys and faucet tokens. No real
value has touched any of this, and none will before entity + counsel +
professional audit — that ordering is a standing rule, not a preference.*

## Design Q&A (from the design walkthrough, 2026-08-28)

**Is there a prepayment penalty?** No, deliberately: the product's normal path
IS continuous early repayment (each epoch's rewards pay down ahead of the
deadline), so penalizing prepayment would fight the core mechanic. Interest
accrues only for epochs that actually pass; full repayment releases margin
immediately.

**Do you repay the agreed FLR amount regardless of price?** Only in the
fixed-FLR loan type — that is the forward-sale deal (coins locked at day-one
price, lender keeps upside, borrower gets the cheapest rate). The fixed-dollar
loan type owes dollars, repaid in FLR valued at the live oracle price at each
payment (borrower keeps upside, higher rate).

**Open consideration:** a lender pricing for a full term can be repaid early
and earn less interest than expected. If real lenders push back, add an
OPTIONAL consented minimum-interest term (accrue at least N epochs' interest
even if repaid sooner) — a per-loan choice, never a hidden penalty.

**HELOC / revolving line? (2026-08-28)** Decided: discrete loans that
CHAIN, not a standing revolver. The pitch's "payoff and revolve" is preserved —
margin releases at payoff and immediately backs the next loan — while a true
draw/repay/redraw line would add committed-capital management, redraw
repricing, and long-lived state (exactly the bug surface the reviews kept
finding), for marginal borrower benefit. Serial loans also reprice at the
CURRENT pass-rate each time, which is better underwriting than a stale line.
If borrowers later want a tap-without-resigning line, build it post-audit as a
wrapper over these loans, not a rewrite.

## The everyday-holder product — self-contained delegator loans (2026-08-28)

Decided + BUILT: the same engine serves every FLR delegator, not just
validators. Three design answers to "how does a normal person without passes
get a rate":

1. **Rate inherits from your provider.** A delegator's stream reliability IS
   the provider they staked with — and that provider has a pass record. The
   keeper posts the provider's passes on the delegator's row, so delegating to
   a 3-pass provider earns the 3-pass rate. Zero code change (the rate formula
   already keys off a pass count). Bonus: it pays people to delegate to
   reliable providers — exactly what the network wants.
2. **Fallback:** a 0-pass record simply pays the top of the band
   (benchmark + 4pts) — an honest "set rate" already in the code.
3. **Self-contained mode (BUILT — `offerStream`):** the margin escrow
   delegates to an FTSO provider and routes its OWN FSP earnings to the loan's
   collector. The locked collateral generates the repayment stream, and the
   borrower cannot switch it off because the escrow holds the stake. This is
   likely the best consumer version — the loan repays itself from its own
   collateral. `MarginEscrow` now has two modes (validator: delegate-to-
   borrower, keep earnings; delegator: delegate-to-provider, earnings->
   collector). Tests in DelegatorLoan.t.sol.

**One site, one vault, two doors** — not two codebases. Same loan engine;
the front end shows "I run a validator" vs "I stake FLR" with different
underwriting displays.

**Honest limit:** per-delegator rewards are NOT individually Merkle-provable
(Flare's reward tree records the provider's pool, not each staker's cut), so
delegator underwriting uses the trusted-keeper lane. Mechanism: proven.
Trustless per-delegator underwriting: future work.

**Framing rule (tax):** never market this as tax avoidance. "Spend without
selling your stack" is true and safe everywhere; staking/validator rewards are
generally ordinary income when earned regardless of what repays the loan.
Real tax treatment (esp. the fixed-FLR forward-sale loan type) is a question for
licensed counsel, already in the roadmap before any real funds.

## Two doors, one rule: "we only lend against streams that can't run away" (2026-08-28)

Design call: NO free-floating/revocable delegation as a lending basis. Only
committed streams, and the commitment must be on-chain-visible. Built:

- **Door 1 — Validators / P-chain stakers (Tier A, `offerStaked`).** The
  borrower has a live P-chain stake (read from Flare's PChainStakeMirror,
  0xd2a1Bb23…9F1D on Coston2) of at least `minStake` to a specific node.
  P-chain stakes cannot exit early and the mirror drops them at end, so the
  rule is enforced by the chain: at accept the stake must be live; if the
  mirror ever shows it gone/short while anything is owed, `trip()` starts the
  default clock (anyone can call). "Your stake must outlive your debt."
  Caveat: P-chain staking has real minimums — verify exact figures from Flare
  docs before quoting; this tier is for larger holders.
- **Door 2 — Escrow-locked delegation (`offerStream`).** The margin escrow
  itself holds the WFLR and delegates it to an FTSO provider, routing its own
  earnings to the loan's collector. The borrower CAN'T undelegate because the
  escrow holds the stake — commitment by construction, no minimum size. The
  everyday-holder door.
- **Rejected — free-floating tokens outside delegation.** Revocable anytime
  => ineligible. Clean story instead of a haircut tier.

Rate for a delegator inherits from the provider's pass record (delegate to a
3-pass provider, get the 3-pass rate). 118 tests (114 local + 4 fork). StakedLoan.t.sol +
DelegatorLoan.t.sol.
