# P-chain Multisig Bond Research — "Self-bond as loan collateral via threshold return owner"

**Date:** 2026-08-27
**Question:** Can a NEW Flare validator self-bond specify a multisig (threshold) owner for the
staked-funds return output and/or rewards owner, so borrower + lender can emulate
"bond principal as loan collateral" today with zero protocol changes?

**VERDICT: PARTIALLY YES.** The principal-collateral half of the hypothesis is **verified at
source level**: the staked-funds return output owner is free-form `OutputOwners` (threshold N-of-M,
optional locktime) with no consensus rule tying it to the staker, and the principal UTXO is
returned at bond expiry with exactly those owners. The rewards-owner half is **moot on Flare**:
P-chain rewards are hardcoded to zero in go-flare, and real staking rewards flow through the
C-chain mirror system keyed to the tx's **inputAddress** — which is actually an enabler, not a
blocker (borrower keeps reward flow; lender secures principal). What blocks full trustless loan
semantics: P-chain has no script, so there is no "lender-only-after-default" unilateral path —
a 2-of-2 return owner requires cooperation (or pre-signed exit txs) to move the principal.
Nothing has been tested on-chain; see UNVERIFIED list before any product commitment.

All findings below are from primary sources fetched 2026-08-27: `flare-foundation/go-flare` at
release tag **v1.14.0** (latest stable; v1.14.2-rc.0 is newest tag; both dated after the Granite
fork so this code is what mainnet enforces), `flare-foundation/flare-smart-contracts-v1` @ main,
`flare-foundation/flare-p-chain-indexer` @ main, `flare-foundation/flare-stake-tool` @ main,
`flare-foundation/developer-hub` @ main, `ava-labs/avalanchejs` @ master.

---

## 1. Which tx type a new Flare self-bond uses, and where the owners live

### 1.1 AddValidatorTx is DEAD on Flare mainnet; AddPermissionlessValidatorTx is the only path

`go-flare/avalanchego/vms/platformvm/txs/executor/staker_tx_verification.go` (v1.14.0):

- Lines 101–104: `verifyAddValidatorTx` returns `ErrAddValidatorTxPostDurango` whenever the
  chain timestamp is past Durango. **Flare mainnet Durango time = 2025-08-05 12:00 UTC**
  (`go-flare/avalanchego/upgrade/upgrade.go`, `Flare = Config{... DurangoTime: time.Date(2025,
  time.August, 5, 12, 0, 0, 0, time.UTC) ...}`, lines 66–82). So the legacy AddValidatorTx that
  Flare staking historically used is no longer accepted.
- Lines 533–537: `verifyAddPermissionlessValidatorTx` has a Flare-specific gate — permissionless
  validator txs rejected **before Cortina** (Flare CortinaTime = 2025-05-13 12:00 UTC). We are
  well past it.
- Flare mainnet fork state today (upgrade.go, Flare config): Cortina 2025-05-13, Durango
  2025-08-05, Etna 2025-12-02, Fortuna 2026-04-14, **Granite 2026-07-14** — all active.

**Conclusion: a NEW self-bond on Flare mainnet today is an `AddPermissionlessValidatorTx` on the
primary network** (with BLS proof-of-possession signer, as on Avalanche). flare-stake-tool
confirms this in practice — it builds `newAddPermissionlessValidatorTx` (see §2).

### 1.2 The tx struct — both owner fields exist and are free-form

`go-flare/avalanchego/vms/platformvm/txs/add_permissionless_validator_tx.go` (identical to
upstream Avalanche), struct `AddPermissionlessValidatorTx`, lines 35–59:

```go
// Where to send staked tokens when done validating
StakeOuts []*avax.TransferableOutput `serialize:"true" json:"stake"`
// Where to send validation rewards when done validating
ValidatorRewardsOwner fx.Owner `serialize:"true" json:"validationRewardsOwner"`
// Where to send delegation rewards when done validating
DelegatorRewardsOwner fx.Owner `serialize:"true" json:"delegationRewardsOwner"`
```

- (a) **Staked UTXO return owner** = the `OutputOwners` inside each `StakeOuts` entry
  (secp256k1fx `TransferOutput`). This is where the principal goes at expiry.
- (b) **Rewards owner(s)** = `ValidatorRewardsOwner` / `DelegatorRewardsOwner` (`fx.Owner`,
  concretely `secp256k1fx.OutputOwners`).

`go-flare/avalanchego/vms/secp256k1fx/output_owners.go` lines 27–33: `OutputOwners{ Locktime
uint64; Threshold uint32; Addrs []ids.ShortID }`. Its `Verify()` (lines ~115–125) only requires:
threshold ≤ len(addrs), threshold ≠ 0 when addrs non-empty, addrs sorted and unique.
**Threshold > 1 with multiple addresses is valid for both the stake outs and the rewards owners.**

### 1.3 No consensus rule ties any of these owners to the staker/funder

Checked exhaustively in v1.14.0:

- `AddPermissionlessValidatorTx.SyntacticVerify` (add_permissionless_validator_tx.go:121–185):
  verifies owners are internally valid (`verify.All`), stake asset = FLR, amounts sum to weight.
  No owner-identity checks.
- `verifyAddPermissionlessValidatorTx` (staker_tx_verification.go:509–639): checks min/max stake,
  duration, delegation fee, duplicate nodeID, and the flow check. No owner-identity checks.
- Flow check `VerifySpendUTXOs` (`vms/platformvm/utxo/verifier.go`, full read): owner-matching is
  enforced **only for stakeable-locked funds** (locktime-tracked per ownerID). Unlocked inputs →
  outputs with **any** owners is fine (lines ~150–160, 244–331). Funding the bond from normal
  unlocked FLR, the StakeOuts may carry any `OutputOwners` whatsoever.

### 1.4 The principal really returns to those owners, automatically

`vms/platformvm/txs/executor/proposal_tx_executor.go`, `rewardValidatorTx`, lines 417–439: when
the staking period ends, the system-issued `RewardValidatorTx` materializes the stake refund as
UTXOs **directly from the original StakeOuts outputs** — same `Out` object, same OutputOwners —
on BOTH the commit and abort branches (i.e., regardless of uptime vote):

```go
utxo := &avax.UTXO{ UTXOID: avax.UTXOID{TxID: txID, OutputIndex: uint32(len(outputs)+i)},
                    Asset: out.Asset, Out: out.Output() }
e.onCommitState.AddUTXO(utxo); e.onAbortState.AddUTXO(utxo)
```

So a StakeOut with `OutputOwners{Threshold: 2, Addrs: [borrower, lender]}` returns the principal
at expiry as a UTXO spendable only 2-of-2. Note the returned UTXO's ID is **deterministic** at
bond-creation time (TxID = staking txID, OutputIndex = len(outputs)+i) — relevant for pre-signed
exit transactions (§5).

### 1.5 Current bond parameters (Granite phase, Flare mainnet)

`txs/executor/inflation_settings.go`, `getFlareInflationSettings`, Granite branch (lines 68–81):
min self-bond **1,000,000 FLR**, max 300M, min duration **60 days**, max 365 days, min delegation
fee **20%** (200,000 / 1,000,000), min delegator stake 50k FLR. (Numerators/denominators: fee is
`DelegationShares` out of `reward.PercentDenominator` = 1,000,000.)

---

## 2. Tooling: everything hardcodes owner = staker, but that is tooling, not protocol

`flare-foundation/flare-stake-tool/src/transaction.ts` (main, lines ~236–300): builds the tx via
avalanchejs with **every owner field set to the user's own single P-address, threshold 1**:

```ts
delegatorRewardsOwner: [futils.bech32ToBytes(ctx.pAddressBech32)],
fromAddressesBytes:    [futils.bech32ToBytes(ctx.pAddressBech32)],
rewardAddresses:       [futils.bech32ToBytes(ctx.pAddressBech32)],
```

(and in the pre-Etna branch, positional `threshold = 1, locktime = 0n`.)

avalanchejs itself (`ava-labs/avalanchejs/src/vms/pvm/etna-builder/builder.ts`,
`newAddPermissionlessValidatorTx`, lines 982–1093):

- **Reward owners**: fully caller-controlled — `rewardAddresses`, `locktime`, `threshold` params
  build `OutputOwners.fromNative(rewardAddresses, locktime, threshold)`. Multisig reward owners
  are one parameter away (moot on Flare, see §4).
- **Stake output owners**: NOT caller-controlled in the high-level builder — `stakeOutputs` come
  out of `spend()` owned by the change owners (`getChangeOutputOwners({changeAddressesBytes,
  fromAddressesBytes})`). To put a 2-of-2 owner on the StakeOuts you must assemble the
  `AddPermissionlessValidatorTx` object directly (all classes — `TransferOutput`, `OutputOwners`,
  `AddPermissionlessValidatorTx`, `UnsignedTx` — are exported and the builder itself constructs
  the tx exactly this way, so a ~100-line custom builder is feasible; only the stakeOutputs array
  changes).

Flare's own docs (`developer-hub/docs/network/guides/using-flare-stake-tool.mdx`) present no
option for custom owners either. **If Tributary wants multisig stake outs, Tributary writes the
tx builder. The protocol accepts it (§1.3); no existing tool emits it.**

---

## 3. P-chain multisig + timelock primitives

### 3.1 How threshold owners sign a spend

`vms/secp256k1fx/fx.go`, `VerifyCredentials` (lines 172–207): an input spending a threshold UTXO
carries `SigIndices` (must select exactly `Threshold` distinct indices into `OutputOwners.Addrs`)
and a credential with signatures in the same order; each recovered pubkey must hash to the
address at its index. Also **line 175–176: `out.Locktime > now → ErrTimelocked`** — the output
locktime is enforced at spend time.

UX reality: no polished multisig wallet exists for Flare's P-chain. avalanchejs supports partial
signing (`UnsignedTx.addSignature` / `addTxSignatures` with multiple keys), so the workflow is
"serialize unsigned tx → each party signs → combine → issue". Ledger signing of a hand-built
P-chain tx works via avalanchejs Ledger support in principle — UNVERIFIED on the touchscreen
devices we use (known cast/Ledger quirks on C-chain suggest testing early).

### 3.2 Timelock primitives — what exists and what doesn't

Two primitives, both verified in source:

1. **`OutputOwners.Locktime`** (output_owners.go:29; enforced fx.go:175): the whole output is
   unspendable by anyone until time T. One locktime per output, shared by all owners.
2. **`stakeable.LockOut`** (`vms/platformvm/stakeable/stakeable_lock.go`): until its locktime the
   wrapped funds can only be staked, not transferred. Historically used for Flare's token
   distribution. `VerifySpendUTXOs` lines 293–318 shows new stakeable-locked outputs CAN be
   created from unlocked funds (locked-produced excess is debited from unlocked-consumed), so
   this primitive is user-reachable, not genesis-only.

**What does NOT exist: per-owner conditional paths.** The P-chain has no script system. A single
UTXO cannot express "lender alone after date X, borrower alone after date Y". The hypothesis's
"1-of-2 with timelock" gives loan semantics to NOBODY: threshold 1 means either party can sweep
the whole output the moment the (single, shared) locktime passes — a race, not an escrow.

Workable owner structures for the returned principal:
- **2-of-2 {borrower, lender}**: neither moves principal alone. Default handling needs
  cooperation, an arbiter key (2-of-3), or pre-signed txs (§5).
- **Split StakeOuts**: multiple stake outputs are allowed (`StakeOuts []*...`, amounts must sum
  to the validator weight — SyntacticVerify lines 153–180). E.g. loan-sized output owned 2-of-2,
  remainder owned by borrower alone. Verified syntactically; economically this is
  over-collateralization plumbing.

---

## 4. CRITICAL Flare-specific fact: P-chain rewards are zero; real rewards are C-chain

### 4.1 The P-chain never pays staking rewards on Flare

`go-flare/avalanchego/vms/platformvm/reward/calculator.go` lines 35–38 (Flare's modification —
upstream Avalanche computes a real reward here):

```go
func (c *calculator) Calculate(stakedDuration time.Duration, stakedAmount, currentSupply uint64) uint64 {
	return uint64(0)
}
```

Unconditional zero, every network this binary serves. Belt-and-braces, Flare's genesis sets
`RewardConfig{... SupplyCap: 0 ...}` (`genesis/genesis_flare.go` lines 62–67). And in
`proposal_tx_executor.go` lines 443–445, the reward UTXO is only created `if reward > 0` — so on
Flare **`ValidatorRewardsOwner` / `DelegatorRewardsOwner` never produce a UTXO. They are inert
fields.** Only the principal-return half of the hypothesis has any on-P-chain effect.

### 4.2 Where rewards actually go: mirror → inputAddress → AddressBinder → C-chain claims

`flare-smart-contracts-v1/contracts/staking/implementation/PChainStakeMirror.sol`,
`mirrorStake()` (lines ~146–160):

```solidity
address cChainAddress = addressBinder.pAddressToCAddress(_stakeData.inputAddress);
require(cChainAddress != address(0), "unknown staking address");
```

The mirrored stake (vote power → staking rewards, FlareDrops, governance) is credited to the
C-chain address **bound to the stake tx's `inputAddress`** — defined in
`contracts/userInterfaces/IPChainStakeMirrorVerifier.sol` as "Input address that triggered the
staking or delegation transaction". `stakingType 0` explicitly covers both `ADD_VALIDATOR_TX`
and — per the off-chain data producer (`flare-p-chain-indexer/utils/staking/utils.go`,
`GetTxType`, lines 159–166) — `AddPermissionlessValidatorTx` as well.

**How inputAddress is derived** (`flare-p-chain-indexer/utils/staking/utils.go`, `DedupeTxs`,
lines 193–212): only rows with **input index 0** are considered, and if input 0's UTXO has
multiple owner addresses, the **lexically smallest address wins** all attribution. Consequence
for bond design: fund the staking tx so that input 0 (in practice: all inputs) comes from the
borrower's single-sig P-address. Do NOT fund from a multisig-owned UTXO — attribution would
collapse onto whichever participant's address sorts lowest.

`IAddressBinder` (`contracts/userInterfaces/IAddressBinder.sol` lines 18–28): binding requires
the **public key** (both addresses are derived from it), so only single-key addresses can ever be
bound — another reason the funding address must be single-sig. (Operational corroboration:
CashLab's own bond wallet had to be registered in AddressBinder before rewards could flow.)

Claim path (docs: `developer-hub/docs/network/guides/using-flare-stake-tool.mdx`, "Claiming
staking rewards"): rewards accumulate every 4 reward epochs (~2 weeks) in a dedicated C-chain
contract (`ValidatorRewardManager`, `flare-smart-contracts-v1/contracts/tokenPools/implementation/ValidatorRewardManager.sol`)
and are claimed by/for the reward owner's 0x address, recipient freely choosable at claim time.
There is additionally the per-epoch FSP (FIP.10) reward path keyed to the same mirrored
attribution. Exact split between the two paths: operationally known to us, not re-derived here.

### 4.3 What this means for the hypothesis

**The rewards-owner half of the hypothesis is irrelevant on Flare — and that's good news.**
Principal control (P-chain, StakeOuts owners) and reward flow (C-chain, inputAddress binding) are
fully independent axes:

- Borrower funds the tx from their bound single-sig address → **all staking rewards, FlareDrops,
  governance vote power stay with the borrower** on the C-chain, claimable through the contracts
  Tributary already integrates. A lender lien on rewards would be a separate C-chain arrangement
  (e.g. claim-recipient agreement or executor pattern) — ordinary EVM territory.
- Lender security lives entirely in the StakeOuts `OutputOwners` on the P-chain.

---

## 5. Verdict and mechanism

**PARTIALLY YES — the principal-collateral mechanism works on Flare mainnet today at the
protocol level; no FIP/fork needed. Full trustless loan semantics (unilateral lender seizure on
default) do NOT exist, and all tooling must be written.**

Mechanism that is consistent with every rule verified above:

1. Borrower (prospective validator) and lender agree terms. Borrower has a bound (AddressBinder)
   single-sig P-address.
2. Custom-built `AddPermissionlessValidatorTx`: funded entirely from borrower's single-sig
   address (inputAddress attribution, §4.2); `StakeOuts` = one output of the loaned amount with
   `OutputOwners{Threshold: 2, Addrs: sort[borrower, lender]}` (optionally plus a borrower-owned
   output for any borrower-contributed portion); duration 60–365 days; ≥1M FLR total; fee ≥20%;
   BLS PoP of the borrower's node. Rewards-owner fields: set to borrower (inert anyway).
3. During the bond: principal is staked and untouchable by anyone (standard staking rule — there
   is no unstake tx; also the reason no consensus rule cares who owns the return output).
   Borrower earns C-chain rewards; node uptime is on the borrower.
4. At expiry: principal UTXO materializes automatically to the 2-of-2 (§1.4). Repayment happy
   path: 2-of-2 co-sign returning principal to borrower (or roll into next bond). Default path:
   2-of-2 co-sign to lender — requires borrower cooperation, OR use **pre-signed exit txs**:
   because the returned UTXO's ID is deterministic at issuance (§1.4), both parties can co-sign,
   at loan origination, a spend of the future UTXO (e.g. to lender, broadcastable only once the
   UTXO exists at expiry). UNVERIFIED: nothing in the verified consensus code forbids signing a
   tx whose input UTXO does not yet exist (signatures commit to tx bytes only, fx.go:187), but
   we have not tested issuance-after-materialization end-to-end; adversarial edge cases (both
   parties holding competing pre-signed spends = race at expiry) need a design pass.

**Main blocker** (if we call anything a blocker): no P-chain script/covenant → default
resolution is cooperative-or-pre-signed, not unilateral; and the entire signing/tx-building
stack (multisig StakeOuts builder, partial-sign relay between borrower and lender, Ledger
integration) is greenfield. **Main enabler**: Flare's own quirk — zero P-chain rewards +
inputAddress-keyed C-chain rewards — cleanly separates lender principal security from borrower
reward economics, which is exactly the shape a validator-credit product wants.

### Tooling to be written

1. Tx builder: hand-assembled `AddPermissionlessValidatorTx` with custom StakeOuts owners
   (avalanchejs classes; ~small). 2. Two-party partial-signing flow (serialize → sign → sign →
   issue) incl. hardware-wallet support. 3. Pre-signed exit tx kit (deterministic UTXOID calc,
   storage, broadcast-at-expiry watcher). 4. Monitoring: bond-expiry watcher + mirror/binding
   verification for the borrower address.

### UNVERIFIED (honest list — none of these were observed on-chain)

- **No end-to-end test performed.** Everything above is source-level verification of go-flare
  v1.14.0 + contracts; no multisig-StakeOuts tx has been issued by us on Coston2/mainnet. A
  Coston2 dry-run (min stake 100k CFLR, min duration 24h per inflation_settings.go:219-231) is
  the mandatory next step before any product claim.
- Whether the deployed mainnet binary is exactly v1.14.x (Granite activation 2026-07-14 implies
  ≥v1.13, and v1.14.0 is the current release, but I did not fingerprint a live node).
- Pre-signed-future-UTXO spend flow (§5 step 4) — consensus code appears to permit it; untested.
- Whether FIP.10 validator-eligibility checks or any FSP component care about StakeOuts owners
  (attribution analysis says no — everything keys on inputAddress — but not tested).
- Exact current split of C-chain reward flows (ValidatorRewardManager 14-day cycle vs FSP
  per-epoch) for a self-bond; operationally familiar, not re-derived in this session.
- Ledger UX for hand-built P-chain txs on touchscreen devices.
- Explorer/tooling behavior (Flarescan, flare-stake-tool display) when confronted with a
  threshold-owned stake — cosmetic but affects support burden.

---

## Source citations (all fetched 2026-08-27)

go-flare @ v1.14.0 (https://github.com/flare-foundation/go-flare/tree/v1.14.0):
- `avalanchego/vms/platformvm/txs/add_permissionless_validator_tx.go` (struct lines 35–59; SyntacticVerify 121–185)
- `avalanchego/vms/platformvm/txs/add_validator_tx.go` (legacy struct, lines 29–42)
- `avalanchego/vms/platformvm/txs/executor/staker_tx_verification.go` (AddValidatorTx post-Durango kill 101–104; Flare Cortina gate 533–537; permissionless verification 509–639)
- `avalanchego/vms/platformvm/txs/executor/inflation_settings.go` (Flare Granite params 68–81; Coston2 219–231)
- `avalanchego/vms/platformvm/txs/executor/proposal_tx_executor.go` (stake refund 417–439; reward>0 gate 443–445)
- `avalanchego/vms/platformvm/reward/calculator.go` (Calculate → 0, lines 35–38)
- `avalanchego/genesis/genesis_flare.go` (SupplyCap 0, lines 62–67)
- `avalanchego/vms/secp256k1fx/output_owners.go` (Locktime/Threshold/Addrs 27–33; Verify ~115–125)
- `avalanchego/vms/secp256k1fx/fx.go` (VerifyCredentials 172–207; ErrTimelocked 175)
- `avalanchego/vms/platformvm/stakeable/stakeable_lock.go` (LockOut/LockIn)
- `avalanchego/vms/platformvm/utxo/verifier.go` (VerifySpendUTXOs owner tracking; locked-from-unlocked 293–318)
- `avalanchego/upgrade/upgrade.go` (Flare fork times, lines 66–82)

flare-smart-contracts-v1 @ main:
- `contracts/staking/implementation/PChainStakeMirror.sol` (mirrorStake inputAddress→AddressBinder, ~146–160)
- `contracts/userInterfaces/IPChainStakeMirrorVerifier.sol` (PChainStake struct, inputAddress definition)
- `contracts/userInterfaces/IAddressBinder.sol` (public-key-based registration, lines 18–28)
- `contracts/tokenPools/implementation/ValidatorRewardManager.sol` (C-chain reward claims)

flare-p-chain-indexer @ main:
- `utils/staking/utils.go` (ToStakeData 120–139; GetTxType 159–166; DedupeTxs input-0 + lexically-smallest 193–212)
- `database/pchain_queries.go` (PChainTxData / input-address join, 219–250)

flare-stake-tool @ main: `src/transaction.ts` (hardcoded single-address owners, ~236–300)
avalanchejs @ master: `src/vms/pvm/etna-builder/builder.ts` (newAddPermissionlessValidatorTx 982–1093)
developer-hub @ main: `docs/network/guides/using-flare-stake-tool.mdx` (claiming staking rewards on C-chain; 3.5-day epochs, 4-epoch claim cadence)
