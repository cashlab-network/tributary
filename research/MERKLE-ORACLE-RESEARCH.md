# Merkle-Verified Oracle Research — can PassLedgerOracle verify reward posts against Flare's on-chain roots?

Date: 2026-08-27. Researcher: Claude (research agent), for the Tributary validator-credit protocol.

**Answer: YES for reward amounts — feasible, cheap, and proven end-to-end below. NO for FIP.10
pass counts — those have no on-chain commitment and stay in the trusted-poster lane.**

Every claim below is cited to a primary source (flare-foundation GitHub at pinned commit
`b69873e1e1a0785e2450d811f35c7927a625716b`, 2026-07-14) or to a `cast` command actually run on
2026-08-27 with its output reproduced. Anything not verified is labeled UNVERIFIED.

---

## 1. The exact on-chain interface

### 1a. Which contract stores the roots: **FlareSystemsManager** (NOT RewardManager)

RewardManager verifies proofs but holds no roots; it calls out to FlareSystemsManager, which owns
the per-epoch root mapping.

`contracts/protocol/implementation/FlareSystemsManager.sol` (lines 125–133):

```solidity
    mapping(uint256 rewardEpochId => bytes32) public uptimeVoteHash;          // L125

    mapping(uint256 rewardEpochId => bytes32) public rewardsHash;             // L128  <-- THE ROOT

    mapping(uint256 rewardEpochId => mapping(uint256 rewardManagerId => uint256)) public noOfWeightBasedClaims;  // L131
    mapping(uint256 rewardEpochId => bytes32) public noOfWeightBasedClaimsHash; // L133
```

Source: https://raw.githubusercontent.com/flare-foundation/flare-smart-contracts-v2/main/contracts/protocol/implementation/FlareSystemsManager.sol

**Read function** (auto-generated public-mapping getter):

```solidity
function rewardsHash(uint256 _rewardEpochId) external view returns (bytes32);
```

`bytes32(0)` means "not signed yet" — RewardManager itself uses that sentinel
(`RewardManager.sol` L1278: `return flareSystemsManager.rewardsHash(_rewardEpochId) != bytes32(0);`).

### 1b. The claim leaf: struct, encoding, hashing

`contracts/userInterfaces/LTS/RewardsV2Interface.sol` (lines 9–24), verbatim:

```solidity
    /// Claim type enum.
    enum ClaimType { DIRECT, FEE, WNAT, MIRROR, CCHAIN }        // 0,1,2,3,4

   /// Struct used for claiming rewards with Merkle proof.
    struct RewardClaimWithProof {
        bytes32[] merkleProof;
        RewardClaim body;
    }

    /// Struct used in Merkle tree for storing reward claims.
    struct RewardClaim {
        uint24 rewardEpochId;
        bytes20 beneficiary; // c-chain address or node id (bytes20) in case of type MIRROR
        uint120 amount; // in wei
        ClaimType claimType;
    }
```

Source: https://raw.githubusercontent.com/flare-foundation/flare-smart-contracts-v2/main/contracts/userInterfaces/LTS/RewardsV2Interface.sol
(re-exported by `contracts/userInterfaces/IRewardManager.sol`, which inherits `RewardsV2Interface`).

**Leaf hashing** — `contracts/protocol/implementation/RewardManager.sol`:

- L640 (direct/fee path) and L694 (weight-based path):
  ```solidity
  bytes32 claimHash = keccak256(abi.encode(rewardClaim));
  ```
  i.e. **keccak256 of the plain `abi.encode` of the 4-field struct** (4 × 32-byte words:
  uint24 left-padded, bytes20 RIGHT-padded, uint120 left-padded, enum as uint8 left-padded).
  The claim hash IS the tree leaf — there is no second hashing of the leaf.

- **Proof verification** — `RewardManager.sol` L1319–1327:
  ```solidity
  function _checkMerkleProof(
      RewardClaimWithProof calldata _proof,
      bytes32 _claimHash
  )
      private view
  {
      bytes32 rewardsHash = flareSystemsManager.rewardsHash(_proof.body.rewardEpochId);
      require(_proof.merkleProof.verifyCalldata(rewardsHash, _claimHash), "merkle proof invalid");
  }
  ```
  `verifyCalldata` is **OpenZeppelin `MerkleProof`** (imported at L20: `@openzeppelin/contracts/utils/cryptography/MerkleProof.sol`,
  `using MerkleProof for bytes32[]` at L29) — i.e. **commutative sorted-pair keccak hashing**
  (`keccak256(min(a,b) ‖ max(a,b))` at each level). Proven by re-derivation in §1d below.

Source: https://raw.githubusercontent.com/flare-foundation/flare-smart-contracts-v2/main/contracts/protocol/implementation/RewardManager.sol

### 1c. How roots get on-chain (who writes `rewardsHash`)

`FlareSystemsManager.signRewards` (L507–547): any voter of the epoch submits
`(rewardEpochId, noOfWeightBasedClaims[], rewardsHash, signature)`. Signatures accumulate weight;
when accumulated weight **exceeds the epoch threshold (>50% of signing weight)** the hash is
written (L1039–1041 in `_updateRewardsHashAndEmitRewardsSigned`:
`rewardsHash[_rewardEpochId] = _rewardsHash;`). Preconditions (L515–517, L1179–1184):
epoch must be over, next epoch's signing policy signed, **uptime vote hash signed first**, and
`require(rewardsHash[_rewardEpochId] == bytes32(0), "rewards hash already signed")` — so the
voter path can set each epoch's root exactly once.

**Governance override exists**: `setRewardsData` (L556–572) is `onlyImmediateGovernance` and
calls the same updater **without** the already-signed check — governance can overwrite a signed
root. See gotcha §6.5.

### 1d. Proven on-chain + cryptographic round-trip (commands actually run, 2026-08-27)

Registry → FSM address (registry `0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019` is the same on all
Flare networks; verified on Coston2 and Flare below):

```
$ cast call 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019 \
    "getContractAddressByName(string)(address)" "FlareSystemsManager" \
    --rpc-url https://flare-api.flare.network/ext/C/rpc
0x89e50DC0380e597ecE79c8494bAAFD84537AD0D4

$ cast call 0x89e50DC0380e597ecE79c8494bAAFD84537AD0D4 "rewardsHash(uint256)(bytes32)" 426 \
    --rpc-url https://flare-api.flare.network/ext/C/rpc
0xc637d57802c32946195c889e07156cdbb21431ff9d365b169efdaf8c71c3b9d9
```

The published file `fsp-rewards/flare/426/reward-distribution-data.json` carries
`"merkleRoot": "0xc637d578...b9d9"` — **byte-identical to the on-chain value**.

Then the full leaf-to-root re-derivation, using the file's FIRST claim
(WNAT, beneficiary `0x00031123b50cdd187dc4d2982164b5458061b463`, amount `4979111432140487620031`,
epoch 426) and its 8-element `merkleProof` from the same file:

```
$ ENC=$(cast abi-encode "f((uint24,bytes20,uint120,uint8))" \
    "(426,0x00031123b50cdd187dc4d2982164b5458061b463,4979111432140487620031,2)")
$ cast keccak "$ENC"
0x0a2fb1a4d20ad0d79b5afcbe9ba3470d1537d45aef0f2b0b1b3e064c7f2f5ad2   # leaf
# fold with sorted-pair keccak through the 8 proof nodes ->
computed root: 0xc637d57802c32946195c889e07156cdbb21431ff9d365b169efdaf8c71c3b9d9
on-chain root: 0xc637d57802c32946195c889e07156cdbb21431ff9d365b169efdaf8c71c3b9d9   # MATCH
```

This proves the entire pipeline independently: encoding, leaf hash, sorted-pair hashing, and the
on-chain root. **A lying poster is impossible for any value covered by the leaf.**

---

## 2. Does the claim data cover underwriting needs?

**Yes for amounts and types; the leaf is exactly `(epoch, beneficiary, amount, claimType)`.**
A third-party contract can verify "beneficiary X earned amount Y of type T in epoch E" with a
pure `view` path — read `rewardsHash(E)`, hash the claim, verify the proof — **without executing
the claim** and without touching RewardManager at all. (RewardManager's claim execution adds
ownership checks, burn factors, double-claim marking — none of which gate verification.)

Claim-type semantics (epoch 426 mainnet file: 93 WNAT, 7 DIRECT, 167 MIRROR, 94 FEE claims):

| ClaimType | beneficiary | amount means | underwriting use |
|---|---|---|---|
| DIRECT (0) | c-chain address | direct payment to that address | provider income (e.g. FDC-related direct rewards) |
| FEE (1) | provider's identity address | **provider's own fee take** for the epoch | THE per-provider income number |
| WNAT (2) | provider's identity address | TOTAL pool for that provider's WNAT delegators | community pool, NOT provider income |
| MIRROR (3) | **node id (bytes20)**, not an address | TOTAL pool for that node's P-chain stakers | staking community pool; validator's own cut = their stake fraction |
| CCHAIN (4) | address | c-chain stake pool (unused/rare on Flare) | — |

Real examples from `flare/426/reward-distribution-data.json`:
FEE `{0x04cfe617fabd..., amount 33449244802828102405745}`;
MIRROR `{0x02e36a47005e1b968e..., amount 102254644365254965109144}` (that bytes20 is a node ID).

For "what does validator X earn per epoch," the verifiable numbers are its **FEE claim** (and any
DIRECT claims to its address). Its share of MIRROR/WNAT pools requires stake/delegation weights,
which are NOT in the tree (see gotcha §6.1).

---

## 3. Off-chain publication of trees / claim files

**Repo: `github.com/flare-foundation/fsp-rewards`** — "the files describing the reward
distribution on Flare networks for each reward epoch," from reward epoch 227 onward (per its
README; earlier data was in the FTSO-Scaling repo).

- Layout: `<network>/<reward-epoch-id>/`, networks present: **`flare` and `songbird` ONLY**
  (verified via GitHub API directory listing, 2026-08-27; `flare/` had 199 epoch dirs, latest `426`).
- Per-epoch files (listing of `flare/426/`, sizes in bytes):
  - `reward-distribution-data.json` (327,278) — `{rewardEpochId, network, appliedMinConditions,
    rewardClaims[], noOfWeightBasedClaims, merkleRoot, abi}`. **Each `rewardClaims[i]` already
    contains its own `merkleProof: bytes32[]` plus the `body` struct** — the keeper does not even
    need to build the tree; it lifts leaf + proof straight from the file.
  - `reward-distribution-data-tuples.json` (299,120) — same data in ABI-tuple form.
  - `reward-epoch-info.json` (294,948)
  - `passes.json` (21,135) — FIP.10 data, see §4.
  - `minimal-conditions.json` (853,270)
- Raw URL pattern:
  `https://raw.githubusercontent.com/flare-foundation/fsp-rewards/main/<network>/<epoch>/<file>`
- The `abi` field inside `reward-distribution-data.json` is the exact `RewardClaim` tuple ABI
  (`uint24 rewardEpochId, bytes20 beneficiary, uint120 amount, uint8 claimType`) — matches §1b.

Independent recomputation (if we ever want not to trust the repo): repo
`flare-foundation/fsp-reward-calculator` "produces a reward Merkle root hash and claims for a
specified epoch"; `-n` accepts **coston, songbird, flare** (README, fetched 2026-08-27); needs a
Flare indexer DB. Output under `./results/<network>/<epoch>`.

---

## 4. FIP.10 pass/strike data: NO on-chain commitment

- `passes.json` per epoch in `fsp-rewards` is the primary published source. Schema (epoch 426):
  `[{rewardEpochId, dataProviderName?, eligibleForReward: bool, voterAddress, passes: 0..3,
  failures: [{protocolId, failureId}]}]` — e.g. failureIds `FTSO_SCALING_FAILURE` (protocolId 100),
  `FDC_FAILURE` (protocolId 200).
- On-chain, FlareSystemsManager stores exactly three per-epoch hashes: `uptimeVoteHash` (L125),
  `rewardsHash` (L128), `noOfWeightBasedClaimsHash` (L133). **None commits to passes.json.**
  The rewards Merkle tree's leaves are `RewardClaim` structs only — no pass counts.
- Passes influence the tree only indirectly: `appliedMinConditions: true` means ineligible
  providers' claims are zeroed/withheld, so "provider had a FEE claim in the signed tree" is weak
  on-chain evidence of eligibility — but the pass COUNT (0–3) is not provable on-chain.
- **Conclusion: pass counts stay in the trusted-poster lane (or a keeper-signed attestation
  lane).** Verified by reading the FSM storage layout and the tree contents; labeling the
  stronger claim "no OTHER Flare contract commits to passes anywhere" as UNVERIFIED (nothing in
  the FSP contract set suggests one exists).

---

## 5. Solidity sketch: `postWithProof` for PassLedgerOracle

Uses the real types from §1. This makes the *reward amount* trustless; pass counts would remain
on the (separate) trusted `post` path.

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IFlareSystemsManager {
    function rewardsHash(uint256 _rewardEpochId) external view returns (bytes32);
}

interface IFlareContractRegistry {
    function getContractAddressByName(string calldata _name) external view returns (address);
}

contract PassLedgerOracleV2 {
    using MerkleProof for bytes32[];

    /// Mirrors RewardsV2Interface.ClaimType (flare-smart-contracts-v2,
    /// contracts/userInterfaces/LTS/RewardsV2Interface.sol L10).
    enum ClaimType { DIRECT, FEE, WNAT, MIRROR, CCHAIN }

    /// Mirrors RewardsV2Interface.RewardClaim (ibid. L19-24). Field order and
    /// types MUST match exactly — the leaf is keccak256(abi.encode(claim)).
    struct RewardClaim {
        uint24 rewardEpochId;
        bytes20 beneficiary; // c-chain address, or node id for MIRROR
        uint120 amount;      // wei
        ClaimType claimType;
    }

    // Same address on every Flare network: 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019
    IFlareContractRegistry public immutable registry;

    /// beneficiary => epoch => claimType => proven amount (0 = not proven; a
    /// genuine zero-amount leaf is possible in theory, so track a flag too).
    struct Proven { uint120 amount; bool proven; }
    mapping(bytes20 => mapping(uint24 => mapping(ClaimType => Proven))) public provenRewards;

    error RootNotSigned(uint24 epochId);
    error InvalidProof();
    error AlreadyProven();

    event RewardProven(bytes20 indexed beneficiary, uint24 indexed epochId,
        ClaimType claimType, uint120 amount);

    constructor(IFlareContractRegistry registry_) { registry = registry_; }

    /// @notice Permissionless: anyone (our keeper, the borrower, an auditor)
    ///         can post, because the proof — not the caller — is the authority.
    function postWithProof(RewardClaim calldata claim, bytes32[] calldata merkleProof) external {
        // Resolve FSM at call time — Flare redeploys behind the stable registry.
        bytes32 root = IFlareSystemsManager(
            registry.getContractAddressByName("FlareSystemsManager")
        ).rewardsHash(claim.rewardEpochId);
        if (root == bytes32(0)) revert RootNotSigned(claim.rewardEpochId);

        // EXACTLY RewardManager.sol L640 + L1326: leaf = keccak256(abi.encode(struct)),
        // verified with OpenZeppelin sorted-pair keccak.
        bytes32 leaf = keccak256(abi.encode(claim));
        if (!merkleProof.verifyCalldata(root, leaf)) revert InvalidProof();

        Proven storage p = provenRewards[claim.beneficiary][claim.rewardEpochId][claim.claimType];
        if (p.proven) revert AlreadyProven();
        (p.amount, p.proven) = (claim.amount, true);
        emit RewardProven(claim.beneficiary, claim.rewardEpochId, claim.claimType, claim.amount);

        // Underwriting fold (trailing average over FEE claims, etc.) goes here,
        // keyed by address(claim.beneficiary) for FEE/DIRECT types.
    }
}
```

Notes:
- Gas is trivial: one external `view` call + one keccak per proof level (~8 levels for ~361
  claims on mainnet epoch 426).
- The keeper's job shrinks to: fetch `reward-distribution-data.json`, pick the borrower's
  claims, submit `(body, merkleProof)` verbatim — both already in the file (§3).
- Keep `post()` (trusted) for pass counts and liveness; the two lanes can coexist in one
  contract with the proven-reward lane overriding the posted reward number.

---

## 6. Limits and gotchas

1. **MIRROR/WNAT amounts are community pools, not the validator's income.** The MIRROR
   beneficiary is a bytes20 **node ID**; the amount is the whole staking-reward pool for that
   node, split pro-rata among stakers at claim time (`RewardManager._claimMirrorRewards` walks
   P-chain stakes). The validator's own cut depends on stake weights that are NOT in the tree.
   The clean, fully-provable per-provider income number is the **FEE claim** (+ DIRECT claims).
2. **Proof of absence is impossible.** The tree proves inclusion only. "Validator X earned
   NOTHING in epoch E" or "X has no FEE claim" cannot be proven on-chain — so a keeper can
   withhold a bad epoch, and the oracle cannot force completeness. Mitigate contract-side:
   underwriting math must treat a MISSING proven epoch as adverse (e.g. the existing
   epoch-monotonic dead-streak logic), not neutral.
3. **Leaf amount is gross-of-burn.** For FEE claims, RewardManager may burn part at claim time
   (`calculateBurnFactorPPM`, RewardManager.sol ~L648) if the provider was late signing —
   the proven amount can exceed what the provider actually receives. Small, but underwriting
   should know the number is "earned," not "banked."
4. **Root timing: ~1 epoch of lag, sometimes more.** A root for epoch N can only be signed after
   N ends AND N+1's signing policy is signed AND N's uptime vote hash is signed, then >50%
   voter weight must sign (§1c). Measured on mainnet 2026-08-27: current epoch **428**; root
   present for 426, **still zero for 427** (epochs are 3.5 days). Plan on FEE data being 1–2
   epochs behind live.
5. **Root finality: immutable via the voter path, but governance can overwrite.**
   `signRewards` refuses a second signing ("rewards hash already signed", FSM L517), but
   `setRewardsData` (FSM L556–572, `onlyImmediateGovernance`) can replace a root with no such
   check. If we cache proven amounts (as the sketch does), a governance root replacement would
   not retro-invalidate our cache. Acceptable risk (it's Flare governance fixing a broken
   calculation), but worth stating in the spec.
6. **Old roots persist forever; claiming expires but verification doesn't.** Verified on
   mainnet: `rewardsHash(240) = 0x58dc22b7...` still readable. RewardManager expires CLAIMS
   (`firstClaimableRewardEpochId`, `closeExpiredRewardEpoch`) but FSM never deletes
   `rewardsHash`. Historical underwriting back to epoch 227 (first published epoch) works.
7. **Coston2: read path proven, but NO published claim files.** Proven 2026-08-27:

   ```
   $ cast call 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019 \
       "getContractAddressByName(string)(address)" "RewardManager" \
       --rpc-url https://coston2-api.flare.network/ext/C/rpc
   0xB4f43E342c5c77e6fe060c0481Fe313Ff2503454
   $ cast call ... "FlareSystemsManager" ...       # same registry, same RPC
   0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52
   $ cast call 0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52 "getCurrentRewardEpochId()(uint24)" ...
   5992
   $ for e in 5988 5989 5990 5991 5992: rewardsHash(e) ->
   5988: 0x0faa4bfbf40337338d133bef7c0e81b837a5a25114c32a38306a1e8a78c3b62e
   5989: 0xf81c8cdf06eeb32d3b5e9ad848d86d9733012acd3f741e70c10752e0b13f3b37
   5990: 0xfd9051e7a4d23d20a4e0dd768768ec2c539d2de225f22514186732237890b292
   5991: 0x0e7b86e124be65482d73af25731edc5b7c0c3fbc5ca55e1dc22d8f19feda6801
   5992: 0x0000000000000000000000000000000000000000000000000000000000000000  (current epoch, unsigned)
   ```

   But `fsp-rewards` publishes only `flare/` and `songbird/`, and `fsp-reward-calculator`'s
   README lists networks `coston, songbird, flare` — **no coston2**. So on Coston2 we can read
   real roots but have no published leaves/proofs to submit; end-to-end testing there needs
   either self-computed trees (calculator + indexer DB, coston2 support UNVERIFIED) or a mock
   FSM seeded with a root we build from synthetic claims. Recommended: unit-test proof logic
   against a mock FSM using real mainnet epoch-426 fixtures (root + leaf + proof from §1d,
   which are known-good), and treat Coston2 as a registry/address integration test only.
8. **Encoding traps for the keeper.** `bytes20` is RIGHT-padded in `abi.encode` while the uints
   are left-padded; the JSON file's `body` lists fields in a different order
   (beneficiary-first) than the Solidity struct (rewardEpochId-first) — always encode in STRUCT
   order. Our oracle's `uint64 epochId` must narrow to the leaf's `uint24`.
9. **One leaf per (epoch, beneficiary, claimType).** Amounts aggregate per type; there is no
   per-protocol breakdown (FTSO vs FDC vs staking fee) inside a FEE leaf. If underwriting wants
   the split, that stays off-chain (reward-epoch-info.json), unproven.

## Primary sources

- https://github.com/flare-foundation/flare-smart-contracts-v2 @ `b69873e1e1a0785e2450d811f35c7927a625716b`
  - `contracts/userInterfaces/LTS/RewardsV2Interface.sol` (struct/enum, L9–24)
  - `contracts/userInterfaces/IRewardManager.sol` (extends RewardsV2Interface)
  - `contracts/protocol/implementation/RewardManager.sol` (L20, L29, L640, L643, L694–695, L1278, L1319–1327)
  - `contracts/protocol/implementation/FlareSystemsManager.sol` (L125–133, L507–547, L556–572, L839–842, L1030–1047, L1179–1184)
- https://github.com/flare-foundation/fsp-rewards (`flare/426/*` files fetched and parsed 2026-08-27)
- https://github.com/flare-foundation/fsp-reward-calculator (README)
- Live chain reads via `cast` on 2026-08-27: Coston2 RPC `https://coston2-api.flare.network/ext/C/rpc`,
  Flare RPC `https://flare-api.flare.network/ext/C/rpc` (all commands + outputs inline above).
- Flare forum "FSP Rewards Data" thread (signing cadence context): https://forum.flare.network/t/fsp-rewards-data/438
