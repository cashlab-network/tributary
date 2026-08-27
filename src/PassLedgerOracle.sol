// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title PassLedgerOracle — the chain-published performance record, on-chain
/// @notice v1 trust model: a poster role publishes, per borrower per reward
///         epoch, values derived from Flare's PUBLIC per-epoch reward and
///         pass files — trailing average reward, FIP.10 pass count, settled
///         epoch count, and whether the stream was alive that epoch. Every
///         posted value is verifiable by anyone against the published files;
///         the poster can be caught lying but v1 does not prevent it
///         (trust-minimization is a later stage, stated openly in the spec).
///         Posts are append-only and strictly epoch-monotonic per borrower.
contract PassLedgerOracle {
    struct Record {
        uint64 epochId; // Flare reward epoch of the latest post
        uint192 trailingRewardPerEpoch; // trailing average FLR reward per epoch (wei)
        uint32 passCount; // FIP.10 passes currently held (0..3)
        uint32 settledEpochs; // total settled epochs in the borrower's history
        uint32 deadStreak; // consecutive epochs with a dead stream
    }

    error NotPoster();
    error EpochNotAfterLast(uint64 posted, uint64 last);
    error ZeroAddress();

    event Posted(
        address indexed borrower,
        uint64 indexed epochId,
        uint192 trailingRewardPerEpoch,
        uint32 passCount,
        uint32 settledEpochs,
        bool alive
    );
    event PosterChanged(address indexed poster);

    address public poster;
    mapping(address => Record) internal records;

    constructor(address poster_) {
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterChanged(poster_);
    }

    /// @notice Hand the poster role over (e.g. deployer -> keeper). The role
    ///         is a single revocable seat, not a standing multi-party grant.
    function setPoster(address poster_) external {
        if (msg.sender != poster) revert NotPoster();
        if (poster_ == address(0)) revert ZeroAddress();
        poster = poster_;
        emit PosterChanged(poster_);
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
        if (msg.sender != poster) revert NotPoster();
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
}
