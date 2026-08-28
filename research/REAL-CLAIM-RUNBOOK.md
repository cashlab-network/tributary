# Tributary — First Real Reward Claim Runbook (Coston2, executor path)

Written 2026-08-27 ~23:59 UTC by read-only research. Every number below was read
from the live Coston2 chain or from flare-foundation source on that date, except
items explicitly marked **UNVERIFIED**. No transactions were sent.

## 0. Verified facts and addresses

| Thing | Value | How verified |
|---|---|---|
| RPC | `https://coston2-api.flare.network/ext/C/rpc` | used for every call below |
| FlareContractRegistry | `0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019` | given, resolves names |
| **RewardManager** | `0xB4f43E342c5c77e6fe060c0481Fe313Ff2503454` | registry `getContractAddressByName("RewardManager")` |
| FlareSystemsManager | `0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52` | registry |
| ClaimSetupManager | `0x5Ddb590530EF66775E6225671eaBD94959e9AE0e` | registry (matches given) |
| WNat | `0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273` | registry (matches given) |
| Delegator EOA (rewardOwner) | `0xB428fdb8fd187eeabeF1De68c136995AD576577e` | given |
| Provider delegation addr | `0x07f5053C867AE107Db15A38Aa4421b2c24aC4e51` | `WNat.delegatesOf(EOA)` = 100% (10000 bips) to it |
| RewardCollector | `<COLLECTOR>` | **not deployed yet at research time — fill in** |
| Executor EOA | `<EXECUTOR>` | fill in |
| Reward epoch length | 21600 s (6 h) | `FSM.rewardEpochDurationSeconds()` |
| Current epoch at research time | 5992, ends 2026-08-28 01:00:00 UTC (`currentRewardEpochExpectedEndTs` = 1787878800) | FSM |
| EOA WNat balance at research time | 18.524717970184321271 WFLR (was ~1.99 earlier; more was wrapped 22:04–23:27 UTC) | `WNat.balanceOf` |
| Delegate tx block | 34570021, 2026-08-27 **23:09:04 UTC** (`delegate(address,uint256)` selector `0x026e402b`) | Coston2 explorer txlist |
| `ClaimSetupManager.claimExecutors(EOA)` | `[]` — **not set yet** | cast call |
| `ClaimSetupManager.allowedClaimRecipients(EOA)` | `[]` — **not set yet** | cast call |

## 1. When do rewards become claimable, and which epoch do we first earn in?

### The vote power block (VPB) rule — from source

`FlareSystemsManager.sol` (flare-smart-contracts-v2, `contracts/protocol/implementation/FlareSystemsManager.sol`,
`_selectVotePowerBlock`): the vote power block for reward epoch N is a **single
random block** drawn from the window between the random-acquisition start of
epoch N-1 and the random-acquisition start of epoch N. Random acquisition for
epoch N starts `newSigningPolicyInitializationStartSeconds` = **7200 s (2 h)
before epoch N starts** (read live from FSM). So the snapshot for epoch N is a
random block inside a ~6 h window ending 2 h before N begins — always **before
epoch N starts**. `RewardManager._claimWNatRewards` then reads
`wNat.balanceOfAt(owner, votePowerBlock)` and `wNat.delegatesOfAt(owner, votePowerBlock)`:
only WNat delegated **at that one block** earns for epoch N.

### Applied to us (all read from chain)

- VPB(5992) = block 34550206 (2026-08-27 18:00:29 UTC): `balanceOfAt(EOA)` = **0** → no rewards for 5992.
- VPB(5993) = block 34566191 (2026-08-27 20:54:21 UTC): `balanceOfAt(EOA)` = **0** → no rewards for 5993. (Our wrap+delegate happened 22:04–23:09 UTC.)
- VPB(5994): not selected yet at research time (`getVotePowerBlock(5994)` reverts / `getRandomAcquisitionInfo(5994)` = 0). Its selection window opened at `randomAcquisitionStartBlock(5993)` = block 34569771 (2026-08-27 **23:00:05 UTC**) and closes ~05:00 UTC 2026-08-28. Our delegation was live from block 34570021 (23:09:04 UTC) — only ~250 blocks (~9 min) of the ~6 h window predate it.
  - → **First earning epoch is 5994 with ~97–98% likelihood.** UNVERIFIED until VPB(5994) is selected (~05:00 UTC Aug 28): if the random block lands in 34569772–34570020, weight is 0 and the first earning epoch is **5995** (certain — its whole window post-dates the delegation).
- Epoch 5994 runs 2026-08-28 **07:00–13:00 UTC** (= 00:00–06:00 US Pacific).

### Claimable when?

`RewardManager.claim` requires (from `RewardManager.sol`): epoch finished
(`_checkIsPastRewardEpoch`), and the epoch's **rewards Merkle root posted** to
FlareSystemsManager (`_checkRewardsHashSet` — "rewards hash zero" otherwise).
The root is posted when >50% of signing weight signs it (dev docs + observed).
Observed cadence for epoch 5991: epoch ended 19:00 UTC, signing finished
**20:08 UTC** (`FSM.getRewardsSignInfo(5991)`), on-chain `rewardsHash(5991)` =
`0x0e7b86e1…a6801` — byte-identical to the published file's merkleRoot.
`RewardManager.getRewardEpochIdsWithClaimableRewards()` already returned
(5963, 5991) at 23:59 UTC, i.e. the just-ended epoch was claimable within ~1 h.

**→ Our first claim: epoch 5994, claimable ≈ 2026-08-28 14:00–15:00 UTC
(≈ 7:00–8:00 AM US Pacific, Friday 2026-08-28).**
Claims expire: claimable window observed = 29 epochs (5963–5991) ≈ 7.25 days on Coston2. Don't sit on it.

## 2. The claim call (cited from source)

`RewardsV2Interface.sol` / `RewardManager.sol` (flare-smart-contracts-v2):

```solidity
enum ClaimType { DIRECT, FEE, WNAT, MIRROR, CCHAIN }   // WNAT = 2

struct RewardClaimWithProof { bytes32[] merkleProof; RewardClaim body; }
struct RewardClaim { uint24 rewardEpochId; bytes20 beneficiary; uint120 amount; ClaimType claimType; }

function claim(
    address _rewardOwner,
    address payable _recipient,
    uint24 _rewardEpochId,     // claims ALL epochs from owner's next-claimable UP TO this id
    bool _wrap,                // true => wNat.depositTo(recipient); false => native transfer
    RewardClaimWithProof[] calldata _proofs
) external ... onlyExecutorAndAllowedRecipient(msg.sender, _rewardOwner, _recipient)
  returns (uint256 _rewardAmountWei);
```

- **Proofs are needed only to initialise** a weight-based claim
  (`_initialiseWeightBasedClaim`: verifies the Merkle proof once, stores
  `UnclaimedRewardState{initialised, amount, weight}`). After that, every
  delegator claim is **proofless**: `_claimRewards` requires
  `_allClaimsInitialised || state.initialised` and pays
  `amount * ourVotePower / weight` pro-rata.
- **Verified on Coston2**: `getUnclaimedRewardState(provider, epoch, 2)` returned
  `initialised = true` for epochs 5989, 5990, 5991 (e.g. 5991: amount
  192087856664735743657098 wei, weight 8082780532807209806433266910 wei) —
  someone initialises every epoch, so **our claim is expected to be proofless
  (empty `_proofs`)**. UNVERIFIED that this continues (n=3 observed); fallback in §5.
- `claim(..., _rewardEpochId=N, ...)` sweeps every unclaimed epoch up to N and
  sets `rewardOwnerNextClaimableEpochId = N+1`. Epochs where we had 0 weight
  contribute 0 — verified via `eth_call` (see §4 dry-run note).

## 3. The executor path (cited from source)

`RewardManager._checkExecutorAndAllowedRecipient`: if `msg.sender != rewardOwner`
it calls `ClaimSetupManager.checkExecutorAndAllowedRecipient(msg.sender, owner, recipient)`.
**The executor calls `RewardManager.claim` directly** — ClaimSetupManager is only
the permission registry. (`autoClaim` is the other path but it forces the
recipient to be the owner's WNat/PDA balance — wrong for a RewardCollector.)

`ClaimSetupManager.sol` (flare-smart-contracts-v1, `contracts/claiming/implementation/ClaimSetupManager.sol`):

```solidity
function checkExecutorAndAllowedRecipient(address _executor, address _claimFor, address _recipient) external view {
    ...
    require(ownerClaimExecutorSet[_claimFor].index[_executor] != 0, ERR_ONLY_OWNER_OR_EXECUTOR);
    require(_recipient == _claimFor ||
        ownerAllowedClaimRecipientSet[_claimFor].index[_recipient] != 0 ||
        _recipient == address(_getDelegationAccount(_claimFor)),
        ERR_RECIPIENT_NOT_ALLOWED);
}
```

So: executor must be in `claimExecutors(owner)`; recipient must be the owner
itself, on `allowedClaimRecipients(owner)`, or the owner's PDA. **Our target
(RewardCollector) must be added by the OWNER via `setAllowedClaimRecipients`.**
`setClaimExecutors` is `payable`: it forwards the executor's registered fee.
For a plain unregistered executor EOA the fee is 0 — send value 0
(`_setClaimExecutors` verified: `totalExecutorsFee <= msg.value`, excess refunded).
Note both setters **replace the whole list** (`replaceAll`), not append.

## 4. The runbook — exact commands

```bash
RPC=https://coston2-api.flare.network/ext/C/rpc
RM=0xB4f43E342c5c77e6fe060c0481Fe313Ff2503454
CSM=0x5Ddb590530EF66775E6225671eaBD94959e9AE0e
FSM=0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52
WNAT=0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273
OWNER=0xB428fdb8fd187eeabeF1De68c136995AD576577e
PROV=0x07f5053C867AE107Db15A38Aa4421b2c24aC4e51
COLLECTOR=<RewardCollector address>          # must accept plain native value (payable receive) if _wrap=false
EXECUTOR=<executor EOA>                      # needs a little C2FLR for gas
EPOCH=5994                                   # confirm with step A first
```

### A. Confirm which epoch we actually earn in (any time after ~05:00 UTC Aug 28)

```bash
VPB=$(cast call $FSM "getVotePowerBlock(uint256)(uint64)" $EPOCH --rpc-url $RPC)
cast call $WNAT "votePowerFromToAt(address,address,uint256)(uint256)" $OWNER $PROV $VPB --rpc-url $RPC
# > 0  => epoch 5994 earns. If 0, set EPOCH=5995 and re-check once its VPB exists.
```

### B. One-time owner setup (2 txs, signed by OWNER — prerequisite, currently NOT done: both lists read back empty on 2026-08-27)

```bash
# 1) authorize the executor (payable; 0 value is correct for an unregistered executor)
cast send $CSM "setClaimExecutors(address[])" "[$EXECUTOR]" --value 0 --rpc-url $RPC --private-key $OWNER_KEY
# 2) allow the collector as recipient
cast send $CSM "setAllowedClaimRecipients(address[])" "[$COLLECTOR]" --rpc-url $RPC --private-key $OWNER_KEY
# verify both:
cast call $CSM "claimExecutors(address)(address[])" $OWNER --rpc-url $RPC
cast call $CSM "allowedClaimRecipients(address)(address[])" $OWNER --rpc-url $RPC
```

### C. Wait for claimability (≈ 14:00–15:00 UTC 2026-08-28 for epoch 5994)

```bash
cast call $RM "getRewardEpochIdsWithClaimableRewards()(uint24,uint24)" --rpc-url $RPC   # end must be >= EPOCH
cast call $RM "getUnclaimedRewardState(address,uint24,uint8)((bool,uint120,uint128))" $PROV $EPOCH 2 --rpc-url $RPC
#            ^ want initialised=true  (then the claim is PROOFLESS)
cast call $RM "getStateOfRewardsAt(address,uint24)((uint24,bytes20,uint120,uint8,bool)[])" $OWNER $EPOCH --rpc-url $RPC
#            ^ shows our exact pending amount; print it: expected ~ pool*ours/weight
#              e.g. 5991-sized pool: 192087856664735743657098 * 18524717970184321271 / 8082780532807209806433266910
#              ≈ 4.4e14 wei ≈ 0.00044 C2FLR  (numerator: our 18.52 WFLR; denominator: 8.08e9 WFLR total delegated)
```

### D. THE CLAIM (signed by EXECUTOR — proofless path)

```bash
cast send $RM \
  "claim(address,address,uint24,bool,(bytes32[],(uint24,bytes20,uint120,uint8))[])" \
  $OWNER $COLLECTOR $EPOCH false '[]' \
  --rpc-url $RPC --private-key $EXECUTOR_KEY
```

Call-shape verified read-only on 2026-08-27: the identical calldata (epoch 5991,
empty proofs, and separately with a real 5-node proof tuple) was executed via
`eth_call` against the live RewardManager and returned cleanly (0 wei, since we
had no weight yet) — no revert, so the signature string and tuple encoding above
are correct as written.

### E. Fallback — proofs, if `initialised` is still false for our epoch

Coston2 reward data is NOT in `flare-foundation/fsp-rewards` (that repo holds
only `flare/` and `songbird/`). The signing-tool README names the testnet
source: **https://gitlab.com/timivesel/ftsov2-testnet-rewards** (UNVERIFIED that
this stays the long-term home — it is a personal GitLab namespace, but it is
what Flare's own signing-tool documents, it was updated 2026-08-27 20:09 UTC,
and its 5991 merkleRoot matches the on-chain `FSM.rewardsHash(5991)` exactly).

URL pattern (verified live for 5991):
`https://gitlab.com/timivesel/ftsov2-testnet-rewards/-/raw/main/rewards-data/coston2/<EPOCH>/reward-distribution-data.json`

```bash
curl -s "https://gitlab.com/timivesel/ftsov2-testnet-rewards/-/raw/main/rewards-data/coston2/$EPOCH/reward-distribution-data.json" \
 | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=[c for c in d['rewardClaims'] if c['body']['beneficiary'].lower()=='0x07f5053c867ae107db15a38aa4421b2c24ac4e51' and c['body']['claimType']==2][0]
proof=','.join(c['merkleProof']); b=c['body']
print(f\"[([{proof}],({b['rewardEpochId']},{b['beneficiary']},{b['body'] if False else b['amount'].rstrip('n')},{b['claimType']}))]\")"
# paste the printed tuple in place of '[]' in step D. (amount field: strip the trailing 'n'.)
# Real 5991 example that exists today: 5-node merkleProof, body (5991, 0x07f5..., 192087856664735743657098, 2).
```

Passing proofs is harmless when already initialised (`_initialiseWeightBasedClaim`
is a no-op if `state.initialised`) — verified via eth_call.

### F. Verify success

```bash
# 1) recipient balance delta (native, since _wrap=false):
cast balance $COLLECTOR --rpc-url $RPC          # before and after; delta = claimed wei
# 2) the event (from the claim tx receipt):
cast receipt <TXHASH> --rpc-url $RPC            # look for RewardClaimed(beneficiary=PROV, rewardOwner=OWNER, recipient=COLLECTOR, epoch, claimType=2, amount)
# 3) state cleared:
cast call $RM "getStateOfRewardsAt(address,uint24)((uint24,bytes20,uint120,uint8,bool)[])" $OWNER $EPOCH --rpc-url $RPC   # now []
cast call $RM "getNextClaimableRewardEpochId(address)(uint256)" $OWNER --rpc-url $RPC    # now EPOCH+1
```

## 5. UNVERIFIED list (everything else above is chain- or source-verified)

1. **First earning epoch 5994 vs 5995** — decided by the random VPB(5994) selection ~05:00 UTC Aug 28; run step A. (~2–3% chance it slips to 5995.)
2. **Per-epoch initialisation keeps happening on Coston2** — observed for 5989–5991 only (n=3). Fallback: step E proofs.
3. **The GitLab repo as durable Coston2 data source** — documented by Flare's signing-tool, root cross-checked for 5991, but a personal namespace.
4. **RewardCollector accepts native transfers** — `_transferOrWrap` uses a low-level call with value when `_wrap=false`; the collector needs a payable receive/fallback, or use `_wrap=true` and pull WNat. Not testable until the contract exists.
5. **Gas for the 31-epoch sweep** (claim iterates every epoch 5963→EPOCH): eth_call executed fine; exact gas not measured.
6. Reward size estimate (~0.00044 C2FLR) assumes a 5991-sized pool and today's 18.52 WFLR balance at the VPB — both change if more is wrapped before the snapshot.
