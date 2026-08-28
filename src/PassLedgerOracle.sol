// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IFlareContractRegistry {
    function getContractAddressByName(string calldata name) external view returns (address);
}

interface IFlareSystemsManager {
    function rewardsHash(uint256 rewardEpochId) external view returns (bytes32);
}

/// @title PassLedgerOracle — the chain-published performance record, on-chain
/// @notice TWO trust lanes:
///  - `post()` (TRUSTED): a poster role copies pass counts, liveness, and a
///    trailing-reward figure from Flare's published files. The poster can be
///    caught lying but this lane does not prevent it.
///  - `postWithProof()` (TRUSTLESS): anyone submits a Flare reward claim leaf
///    plus its Merkle proof; the oracle verifies it against the root Flare's
///    own FlareSystemsManager has signed on-chain. A lying poster is
///    IMPOSSIBLE for a proven reward amount — the proof, not the caller, is
///    the authority. FEE claims are a provider's own income; that is the
///    number underwriting should trust. (FIP.10 pass counts have no on-chain
///    commitment and necessarily stay in the trusted lane — see
///    research/MERKLE-ORACLE-RESEARCH.md.)
///  Posts are append-only and strictly epoch-monotonic per borrower.
contract PassLedgerOracle {
    struct Record {
        uint64 epochId; // Flare reward epoch of the latest post
        uint192 trailingRewardPerEpoch; // trailing average FLR reward per epoch (wei)
        uint32 passCount; // FIP.10 passes currently held (0..3)
        uint32 settledEpochs; // total settled epochs in the borrower's history
        uint32 deadStreak; // consecutive epochs with a dead stream
    }

    /// Mirrors flare-smart-contracts-v2 RewardsV2Interface.ClaimType.
    enum ClaimType {
        DIRECT,
        FEE,
        WNAT,
        MIRROR,
        CCHAIN
    }

    /// Mirrors RewardsV2Interface.RewardClaim EXACTLY — field order and types
    /// are load-bearing: the tree leaf is keccak256(abi.encode(claim)).
    struct RewardClaim {
        uint24 rewardEpochId;
        bytes20 beneficiary; // c-chain address, or node id for MIRROR
        uint120 amount; // wei
        ClaimType claimType;
    }

    error NotPoster();
    error EpochNotAfterLast(uint64 posted, uint64 last);
    error ZeroAddress();
    error RootNotSigned(uint24 epochId);
    error InvalidProof();
    error AlreadyProven();

    event Posted(
        address indexed borrower,
        uint64 indexed epochId,
        uint192 trailingRewardPerEpoch,
        uint32 passCount,
        uint32 settledEpochs,
        bool alive
    );
    event PosterChanged(address indexed poster);
    event BackupPosterSet(address indexed poster, bool allowed);
    event RewardProven(
        bytes20 indexed beneficiary, uint24 indexed epochId, ClaimType claimType, uint120 amount
    );

    address public poster; // primary poster + admin
    mapping(address => bool) public isBackupPoster; // G12: redundancy
    mapping(address => Record) internal records;

    // Trustless lane: proven reward amounts keyed by (beneficiary, epoch, type).
    struct Proven {
        uint120 amount;
        bool proven;
    }

    mapping(bytes20 => mapping(uint24 => mapping(ClaimType => Proven))) public provenRewards;
    // Running total + count of proven FEE claims per beneficiary -> a trailing
    // average that is fully trustless.
    mapping(bytes20 => uint256) public provenFeeSum;
    mapping(bytes20 => uint256) public provenFeeCount;

    /// Same address on every Flare network; the FSM is resolved through it at
    /// call time because Flare redeploys implementations behind the registry.
    IFlareContractRegistry public immutable registry;

    constructor(address poster_, IFlareContractRegistry registry_) {
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        registry = registry_; // may be address(0) in pure unit tests
        emit PosterChanged(poster_);
    }

    /// @notice Hand the primary poster (admin) role over (e.g. deployer ->
    ///         keeper). The primary poster is also the admin that manages the
    ///         backup posters below.
    function setPoster(address poster_) external {
        if (msg.sender != poster) revert NotPoster();
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterChanged(poster_);
    }

    /// @notice Keeper redundancy (G12): the primary poster authorizes backup
    ///         posters, so a single keeper key dying does not freeze the
    ///         trusted lane. postWithProof is already permissionless, so only
    ///         this trusted lane needed a redundancy lever.
    function setBackupPoster(address poster_, bool allowed) external {
        if (msg.sender != poster) revert NotPoster();
        if (poster_ == address(0)) revert ZeroAddress();
        isBackupPoster[poster_] = allowed;
        emit BackupPosterSet(poster_, allowed);
    }

    /// @notice Post one borrower's ledger row for one reward epoch. Epochs
    ///         must strictly increase — history is never rewritten.
    function post(
        address borrower,
        uint64 epochId,
        uint192 trailingRewardPerEpoch,
        uint32 passCount,
        uint32 settledEpochs,
        bool alive
    ) external {
        if (msg.sender != poster && !isBackupPoster[msg.sender]) revert NotPoster();
        if (borrower == address(0)) revert ZeroAddress();
        Record storage r = records[borrower];
        if (epochId <= r.epochId) revert EpochNotAfterLast(epochId, r.epochId);
        r.epochId = epochId;
        r.trailingRewardPerEpoch = trailingRewardPerEpoch;
        r.passCount = passCount;
        r.settledEpochs = settledEpochs;
        r.deadStreak = alive ? 0 : r.deadStreak + 1;
        emit Posted(borrower, epochId, trailingRewardPerEpoch, passCount, settledEpochs, alive);
    }

    function latest(address borrower) external view returns (Record memory) {
        return records[borrower];
    }

    // ---------------------------------------------------- trustless lane (G1)

    /// @notice Prove a Flare reward claim against the root FlareSystemsManager
    ///         has signed on-chain. Permissionless — the proof is the
    ///         authority, not msg.sender. The keeper lifts the leaf `body` and
    ///         `merkleProof` verbatim from Flare's published
    ///         reward-distribution-data.json. FEE claims accumulate into a
    ///         trustless trailing average.
    function postWithProof(RewardClaim calldata claim, bytes32[] calldata merkleProof) external {
        bytes32 root =
            IFlareSystemsManager(registry.getContractAddressByName("FlareSystemsManager")).rewardsHash(claim.rewardEpochId);
        if (root == bytes32(0)) revert RootNotSigned(claim.rewardEpochId);

        // EXACTLY RewardManager's leaf: keccak256(abi.encode(struct)), verified
        // with OpenZeppelin-style commutative sorted-pair keccak.
        bytes32 leaf = keccak256(abi.encode(claim));
        if (!_verify(merkleProof, root, leaf)) revert InvalidProof();

        Proven storage p = provenRewards[claim.beneficiary][claim.rewardEpochId][claim.claimType];
        if (p.proven) revert AlreadyProven();
        p.amount = claim.amount;
        p.proven = true;

        if (claim.claimType == ClaimType.FEE) {
            provenFeeSum[claim.beneficiary] += claim.amount;
            provenFeeCount[claim.beneficiary] += 1;
        }
        emit RewardProven(claim.beneficiary, claim.rewardEpochId, claim.claimType, claim.amount);
    }

    /// @notice Trustless trailing average of proven FEE income (wei/epoch), 0
    ///         if none proven yet. This is the number a future vault can
    ///         underwrite on WITHOUT trusting the poster.
    function provenTrailingFee(bytes20 beneficiary) external view returns (uint256) {
        uint256 n = provenFeeCount[beneficiary];
        return n == 0 ? 0 : provenFeeSum[beneficiary] / n;
    }

    /// Commutative Merkle verification (OpenZeppelin MerkleProof semantics):
    /// keccak256 of the sorted concatenation at each level.
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; i++) {
            bytes32 p = proof[i];
            h = h <= p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }
}
