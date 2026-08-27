// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TermsLib} from "./TermsLib.sol";

/// @title LoanVault — Tributary v1 loan lifecycle (state machine core)
/// @notice Loans are keyed by immutable id in a mapping; no invariant may
///         depend on array position (Debt DAO H-01/H-05). Every lifecycle
///         call asserts the id exists and the loan is in a legal state for
///         that action (H-04). Consent is recorded value-free; funds move
///         only in calls that execute the body (H-03).
///
/// This commit is the state-machine skeleton per SPEC-V1 build order step 1:
/// offer/accept/cancel + the status graph + guards, with funds flows landing
/// in the next build steps (MarginEscrow, RewardCollector integration).
contract LoanVault {
    enum Status {
        None, // id never used — every guard must reject this
        Offered, // lender posted terms; no borrower consent yet
        Open, // both parties consented; margin not yet posted / not drawn
        Drawn, // principal out; repaying from routed rewards
        Triggered, // dead-stream or covenant trigger tripped
        Grace, // 7-day cure window after trigger
        Settled, // margin settled debt + fee; excess returned to borrower
        Repaid, // outstanding reached zero via repayment
        Closed // terminal: released and archived
    }

    struct Loan {
        address borrower;
        address lender;
        // Terms, snapshotted at origination (trailing, never projected):
        uint256 principalFlr; // fixed-FLR debt at origination
        uint256 outstandingFlr; // remaining debt (only ever decreases)
        uint256 marginAmount; // WFLR posted (escrow lands in build step 3)
        uint256 benchmarkBps; // lender-alternative benchmark at origination
        uint16 termEpochs;
        Status status;
    }

    error LoanDoesNotExist(uint256 id);
    error WrongStatus(uint256 id, Status actual, Status required);
    error NotParty(uint256 id, address caller);
    error ZeroAddress();
    error ZeroAmount();

    event LoanOffered(uint256 indexed id, address indexed lender, address indexed borrower);
    event LoanOpened(uint256 indexed id);
    event OfferCancelled(uint256 indexed id);

    uint256 public nextId = 1; // 0 is never a valid id
    mapping(uint256 => Loan) internal loans;

    modifier exists(uint256 id) {
        if (loans[id].status == Status.None) revert LoanDoesNotExist(id);
        _;
    }

    modifier inStatus(uint256 id, Status required) {
        if (loans[id].status == Status.None) revert LoanDoesNotExist(id);
        if (loans[id].status != required) revert WrongStatus(id, loans[id].status, required);
        _;
    }

    /// @notice Lender posts loan terms addressed to one specific borrower.
    ///         Value-free: consent and funds never share a call.
    function offer(address borrower, uint256 principalFlr, uint256 benchmarkBps, uint16 termEpochs)
        external
        returns (uint256 id)
    {
        if (borrower == address(0)) revert ZeroAddress();
        if (principalFlr == 0) revert ZeroAmount();
        id = nextId++;
        loans[id] = Loan({
            borrower: borrower,
            lender: msg.sender,
            principalFlr: principalFlr,
            outstandingFlr: principalFlr,
            marginAmount: 0,
            benchmarkBps: benchmarkBps,
            termEpochs: termEpochs,
            status: Status.Offered
        });
        emit LoanOffered(id, msg.sender, borrower);
    }

    /// @notice Borrower consents to the exact offered terms. Any term change
    ///         requires a fresh offer (M-02: authorization is invalidated when
    ///         its arguments change — terms are immutable per id).
    function accept(uint256 id) external inStatus(id, Status.Offered) {
        if (msg.sender != loans[id].borrower) revert NotParty(id, msg.sender);
        loans[id].status = Status.Open;
        emit LoanOpened(id);
    }

    /// @notice Lender withdraws an un-accepted offer (M-02: no standing "yes"
    ///         with an open expiry — offers are revocable until consumed).
    function cancelOffer(uint256 id) external inStatus(id, Status.Offered) {
        if (msg.sender != loans[id].lender) revert NotParty(id, msg.sender);
        loans[id].status = Status.Closed;
        emit OfferCancelled(id);
    }

    function getLoan(uint256 id) external view exists(id) returns (Loan memory) {
        return loans[id];
    }
}
