// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IFlareContractRegistry {
    function getContractAddressByName(string calldata name) external view returns (address);
}

interface IFlareSystemsManager {
    function rewardsHash(uint256 rewardEpochId) external view returns (bytes32);
    function getCurrentRewardEpochId() external view returns (uint24);
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
    error NotBeneficiary(); // REVIEW4-MA: FEE proofs are self-prove-only
    error WindowTooShort(); // declared window end < minTrailingWindow
    error WindowNotProven(uint24 epoch); // a gap: that epoch's FEE isn't proven

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
    event TrailingWindowDeclared(bytes20 indexed beneficiary, uint24 start, uint24 end);

    address public poster; // primary poster + admin
    mapping(address => bool) public isBackupPoster; // G12: redundancy
    mapping(address => Record) internal records;

    // Trustless lane: proven reward amounts keyed by (beneficiary, epoch, type).
    struct Proven {
        uint120 amount;
        bool proven;
    }

    mapping(bytes20 => mapping(uint24 => mapping(ClaimType => Proven))) public provenRewards;

    /// The trailing FEE figure is computed over an EXPLICIT recent window that
    /// the beneficiary DECLARES: [end - minTrailingWindow + 1, end]. Every epoch
    /// in it must be self-proven (so a borrower can't skip weak epochs — a fixed
    /// contiguous range can't exclude a bad epoch), and `end` must be recent
    /// (checked at read against the current reward epoch — no underwriting off a
    /// stale historical peak). This replaces the old per-beneficiary cumulative
    /// aggregate, which was (a) poisonable — anyone could prove one distant FEE
    /// epoch and permanently break contiguity (REVIEW4-MA) — and (b) a
    /// self-lockout: it never reset, so a borrower got ONE lifetime window.
    /// A declared window is re-declarable, so proving newer epochs never locks
    /// anyone out; they just point at a fresh window. `end == 0` means none.
    mapping(bytes20 => uint24) public trailingEnd;

    /// Same address on every Flare network; the FSM is resolved through it at
    /// call time because Flare redeploys implementations behind the registry.
    IFlareContractRegistry public immutable registry;
    /// Minimum contiguous proven-epoch window for a nonzero trailing figure.
    uint32 public immutable minTrailingWindow;

    constructor(address poster_, IFlareContractRegistry registry_, uint32 minTrailingWindow_) {
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        registry = registry_; // may be address(0) in pure unit tests
        minTrailingWindow = minTrailingWindow_ == 0 ? 8 : minTrailingWindow_;
        emit PosterChanged(poster_);
    }

    /// @notice Hand the primary poster (admin) role over (e.g. deployer ->
    ///         keeper). The primary poster is also the admin that manages the
    ///         backup posters below.
    /// @dev    F6 operational note: rotating the primary does NOT auto-revoke
    ///         backups. If rotating because a key was compromised, revoke any
    ///         now-untrusted backups explicitly via setBackupPoster(_, false).
    function setPoster(address poster_) external {
        if (msg.sender != poster) revert NotPoster();
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterChanged(poster_);
    }

    /// @notice Keeper redundancy (G12): the primary poster authorizes backup
    ///         posters, so a single keeper key dying does not freeze the
    ///         trusted lane. postWithProof needs no redundancy lever: non-FEE
    ///         proofs are permissionless, and FEE proofs are the borrower's
    ///         own to make (REVIEW4-MA) — no keeper in that path at all.
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
    ///         has signed on-chain. The proof is the authority for the AMOUNT.
    ///         FEE claims are self-sovereign (REVIEW4-MA): only the beneficiary
    ///         may populate their own FEE records. Combined with self-only
    ///         window declaration (declareTrailingWindow) and the fixed-range
    ///         windowed average (provenTrailingFee), this makes third-party
    ///         griefing of a borrower's trustless credit line structurally
    ///         impossible — three independent barriers. Non-FEE claim types
    ///         never feed underwriting and stay permissionless. The caller lifts
    ///         the leaf `body` and `merkleProof` verbatim from Flare's published
    ///         reward-distribution-data.json.
    function postWithProof(RewardClaim calldata claim, bytes32[] calldata merkleProof) external {
        // REVIEW4-MA: FEE reward records are self-sovereign — you populate only
        // your own. (Defense-in-depth; the windowed average also ignores any
        // epoch outside your declared window.)
        if (claim.claimType == ClaimType.FEE && msg.sender != address(claim.beneficiary)) {
            revert NotBeneficiary();
        }
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
        // Per-epoch storage IS the source of truth; the trailing window is
        // computed on demand from it (see declareTrailingWindow / provenTrailingFee).
        emit RewardProven(claim.beneficiary, claim.rewardEpochId, claim.claimType, claim.amount);
    }

    /// @notice Declare (or re-declare) the recent contiguous FEE window this
    ///         beneficiary wants underwritten: [end - minTrailingWindow + 1, end].
    ///         Self-only (the window is keyed to msg.sender). Every epoch in the
    ///         window must already be self-proven — a gap reverts, so the range
    ///         is contiguous by construction and cannot skip a weak epoch.
    ///         Re-declarable: proving newer epochs never locks you out; point at
    ///         a fresh window. Recency is enforced later, at read.
    function declareTrailingWindow(uint24 end) external {
        bytes20 who = bytes20(msg.sender);
        if (end < minTrailingWindow) revert WindowTooShort();
        uint24 start = uint24(uint256(end) + 1 - minTrailingWindow);
        for (uint24 e = start; e <= end; e++) {
            if (!provenRewards[who][e][ClaimType.FEE].proven) revert WindowNotProven(e);
        }
        trailingEnd[who] = end;
        emit TrailingWindowDeclared(who, start, end);
    }

    /// @notice Trustless trailing average of proven FEE income (wei/epoch),
    ///         computed from the beneficiary's DECLARED window and re-derived
    ///         from the per-epoch source of truth every read. Returns 0 (fails
    ///         safe) if: no window is declared; the window is no longer fully
    ///         proven; or the window is STALE — its end lags the current reward
    ///         epoch by more than minTrailingWindow (so a borrower can't
    ///         underwrite off a historical peak). Cherry-picking is impossible:
    ///         the window is a fixed contiguous range, so a skipped weak epoch
    ///         has no valid window that spans it.
    function provenTrailingFee(bytes20 beneficiary) external view returns (uint256) {
        uint24 end = trailingEnd[beneficiary];
        if (end < minTrailingWindow) return 0;
        // recency: window end must be within minTrailingWindow of "now"
        uint24 current =
            IFlareSystemsManager(registry.getContractAddressByName("FlareSystemsManager")).getCurrentRewardEpochId();
        if (current > end && current - end > minTrailingWindow) return 0;
        (bool ok, uint256 sum) = _feeWindowSum(beneficiary, end);
        if (!ok) return 0;
        return sum / minTrailingWindow;
    }

    /// Sum the FEE amounts over [end - minTrailingWindow + 1, end]; ok=false on
    /// any unproven epoch. Caller guarantees end >= minTrailingWindow.
    function _feeWindowSum(bytes20 b, uint24 end) internal view returns (bool ok, uint256 sum) {
        uint24 start = uint24(uint256(end) + 1 - minTrailingWindow);
        for (uint24 e = start; e <= end; e++) {
            Proven storage p = provenRewards[b][e][ClaimType.FEE];
            if (!p.proven) return (false, 0);
            sum += p.amount;
        }
        return (true, sum);
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
