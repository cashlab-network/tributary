# Tributary — Security Foundations, inherited from the Debt DAO audit
### Read of the full Code4rena Debt DAO report (Nov 2022, judged Feb 2023) — 6 High, 11 Medium, 78 low/NC, 42 gas, across 2,511 lines. Read cover to cover 2026-08-27 before any Tributary code exists.

Debt DAO is the closest prior art to Tributary: revenue-claim routing (their
Spigot) plus a lender/borrower credit marketplace (their LineOfCredit). They
raised $3.5M, shipped this code to audit, and then went quiet — no shutdown
notice. Their $3.5M bought these lessons; we take them for the price of reading.

This is not a summary for its own sake. Every finding below is sorted into:
**INHERITED** (the same class can bite Tributary — becomes a build rule),
**AVOIDED-BY-DESIGN** (their choice created it; ours doesn't — note why, so we
never reintroduce it), or **HYGIENE** (generic Solidity, fix by default).

---

## The one meta-lesson, before the findings

Look at who the 17 bugs hurt: **the vast majority are the LENDER or BORROWER
attacking each other, or funds locking between them** — not an outside thief.
H-01..H-06 and M-01..M-11 are almost all "one counterparty exploits the other."
That is the shape of every two-sided credit contract, Tributary included. The
design consequence: **treat the borrower and the lender each as a potential
adversary of the other at every state transition** — never assume either acts
in good faith just because they signed the loan. Their sponsor repeatedly tried
to wave findings away with "if you add malicious things, malicious things
happen" (M-05, M-06); the judge repeatedly overruled him ("the user should be
protected against accidentally allowing…"). **We side with the judge, always.**

---

## HIGH findings → Tributary rules

**H-01 / H-05 — the credit-queue array corrupts (position shifts break the
`whileBorrowing` invariant; a crafted sequence makes a loan unliquidatable).**
INHERITED-IN-SPIRIT. Root cause: they tracked positions in a mutable array with
index-shifting (`stepQ`, `_sortIntoQ`, `removePosition`) and hung
load-bearing modifiers off `ids[0]`. → **RULE: Tributary loans are keyed by
immutable id in a mapping; never by array position. No invariant may depend on
"the zeroth element." Every state-machine transition gets an explicit test that
the loan can still be settled/defaulted from that state** (their unliquidatable-
loan bug is the nightmare case for us — a loan that can't be settled is our
whole product failing silently).

**H-02 — unregistered revenue contract passed to `claimRevenue` routes 100% to
the wrong place (borrower drains their own stream away from the lender).**
INHERITED, directly — this is our repayment rail. Their `claimRevenue` didn't
check the revenue contract was registered, defaulted `ownerSplit` to 0, and sent
everything to treasury. → **RULE: the claim/repayment path validates every
address against an explicit allowlist set at loan origination, and reverts on
anything unregistered. Never infer a default split from an unrecognized input.
The Tributary analogue: the reward claim can only ever route to the loan's
registered lender/borrower pair — a garbage or unregistered target reverts, it
does not "route somewhere reasonable."**

**H-03 — two-party consent + ETH payment: first caller's ETH is lost / second
call reverts.** AVOIDED-BY-DESIGN, but note the trap. Cause: `mutualConsent`
executed the body only on the *second* call, but the *first* caller already
attached value. → **RULE: Tributary never mixes value transfer with a consent
handshake in the same call.** Consent is recorded value-free; funds move only in
a call that executes the body. (Also: prefer stablecoin/WFLR flows over native
FLR wherever possible — see the ETH-refund cluster in Medium.)

**H-04 — borrower closes a loan without repaying (close accepted a
non-existent id, decremented the counter, flipped status to REPAID).**
INHERITED. Cause: `close()` never checked the id existed. → **RULE: every
lifecycle function (open/draw/repay/close/default) first asserts the loan id
exists and is in a legal state for that action. Status may only reach REPAID via
the code path that verified principal == 0. Ship the failing test
(`close a bogus id`) in the same commit as the check** (this is literally
CLAUDE.md rule "write the failing case in the same commit").

**H-06 — over-repayment underflows principal to ~2^256 (an `unchecked` block
subtracts more than the principal, forcing liquidation / making repay
impossible).** INHERITED, and it maps straight onto our repayment loop. Cause:
`unchecked { credit.principal -= principalPayment; }` with no bound on the
payment. → **RULE: never `unchecked` a subtraction whose operand isn't proven
≤ the minuend one line above. On every reward-tranche repayment, cap the applied
amount at `min(amount, outstanding)` BEFORE subtracting; the excess is change,
returned or credited, never an underflow.** (On fixed-FLR loans this is where a
big allocation epoch must not wrap the balance — directly load-bearing.)

---

## MEDIUM findings → Tributary rules

**M-02 — mutual consent can never be revoked and lives forever (a stale consent
becomes a latent authorization the counterparty can spring later).** INHERITED,
and it rhymes with our own known front-running/authorization surface. → **RULE:
every authorization Tributary stores is revocable AND scoped — either
time-boxed, single-use (consumed on use, like our X-approval hash-consume
pattern), or invalidated when its arguments change. No standing "yes" with an
open expiry.** Their recommended fix (option 3: invalidate on argument change)
is the one to copy.

**M-04 — lender supplies malicious trade calldata (`zeroExTradeData`) and repays
the loan with dust while pocketing the claimed revenue.** AVOIDED-BY-DESIGN, and
this one is a gift: it's an argument to NOT put a DEX swap inside the repayment
path at all. Their whole `claimAndTrade` attack surface exists because they
converted revenue token → debt token via an external aggregator with
caller-controlled calldata. → **RULE: Tributary's fixed-FLR flavor repays in the
same asset it collects (FLR in, FLR owed) — no in-protocol swap, no external
trade calldata, the entire M-04 class deleted. The fixed-dollar flavor prices
via the FTSO (our own oracle), never a caller-supplied trade blob.** This is a
concrete reason the two-flavor design is *safer*, not just more marketable.

**M-05 / M-06 / M-11 — reentrancy and griefing via token receiver hooks
(ERC-777 / hook tokens let a lender re-enter `close`, steal other lenders'
funds, or block a close by reverting on receive).** INHERITED — the classic. →
**RULES: (1) strict checks-effects-interactions — delete/zero all loan state
BEFORE any external transfer; (2) `nonReentrant` on every state-changing
external entry; (3) an explicit allowlist of accepted assets (USDT0, WFLR,
stXRP) — no arbitrary-token support, which deletes the hook-reentrancy class
wholesale; (4) pull-based withdrawals, not push — the counterparty withdraws
their funds, the protocol never pushes to an address that can revert or
re-enter (their M-11 fix).**

**M-01 / M-03 / M-08 / M-10 — native-ETH handling: wrong payer, excess not
refunded and locked, ETH locked when sent alongside an ERC20, `transfer()` vs
`call()`.** MOSTLY-AVOIDED-BY-DESIGN. Four separate findings all rooted in
supporting native ETH with hand-rolled `receiveTokenOrETH`. → **RULE: Tributary
handles only ERC-20-style assets (USDT0, WFLR, stXRP are all tokens); it does
NOT accept native FLR into contract functions. If native ever must be handled,
use a battle-tested wrapper + `Address.sendValue`, refund any excess in the same
call, and never branch value-handling on token type.** Four bugs, one design
choice, gone.

**M-07 — whitelisted function selectors aren't scoped to a specific contract, so
a selector-clash smuggles a malicious call through the arbiter's review.**
INHERITED-IF-WE-EVER-WHITELIST-SELECTORS. We likely won't (our claim path is
fixed, not an arbitrary operate()), but note it: → **RULE: if Tributary ever
lets an operator whitelist a callable function, scope it to
`(contract, selector)`, never a bare selector.** Otherwise not applicable — our
keeper calls a fixed, known claim interface, not caller-chosen functions.

**M-09 — variable-balance tokens (fee-on-transfer, rebasing, stETH-style) break
spot-balance accounting.** INHERITED, and pointed: **stXRP and WFLR behavior
must be checked here.** Rebasing/variable-balance collateral stored as a spot
amount goes wrong exactly when it matters. → **RULE: measure token movements by
before/after balance delta, or record proportional shares, never a stored spot
amount; and confirm for EACH allowed asset (WFLR, stXRP, USDT0) whether its
balance can move without a transfer — if it can, it needs share accounting, and
if that's too complex, disallow it.** (Directly relevant: is stXRP rebasing?
Answer before it's ever accepted as margin.)

---

## HYGIENE (the 78 low/NC + 42 gas — fix by default, not Tributary-specific)
Zero-address checks on every address setter (L-02); no open TODOs in shipped
code (L-03); descriptive revert strings / custom errors (N-05, G-15);
`nonReentrant` ordered before other modifiers (N-02); fixed compiler pragma, not
floating (N-13); SPDX on every file (N-14); complete NatSpec (N-15); immutable
for constructor-set vars (G-01); `calldata` over `memory` for read-only args
(G-02); cache storage reads (G-05); custom errors over require-strings (G-15).
These are the default standard of care; the professional audit will expect all
of them already done.

---

## What this DOESN'T teach us (stated so we don't over-learn)
Debt DAO's death is not evidence the *mechanism* fails — every bug here is
fixable and most are avoided by our narrower design. Their disappearance tracks
the 2022–23 credit-market collapse and a borrower base (anonymous DAOs, volatile
fee revenue, no credit history) opposite to ours (named validators, protocol-
issued rewards, a public performance ledger). The security lessons transfer; the
business verdict does not. Lender-demand-first still governs whether we build at
all (see RESEARCH-VALIDATOR-CREDIT-LANDSCAPE + the Alkimiya lesson).

**Bottom line for Tributary's eventual spec:** narrow the asset set to an
allowlist; key loans by id not array position; validate id + state on every
lifecycle call; cap every repayment subtraction; checks-effects-interactions +
nonReentrant + pull-withdrawals everywhere; no in-protocol swaps (flavors make
this free); revocable/scoped authorizations; balance-delta accounting for any
non-standard token; ship each failing case with its check. Most of Debt DAO's
17 either can't occur in this design or are one build rule away from closed —
before we've written a line.
