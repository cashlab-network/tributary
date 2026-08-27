// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TermsLib} from "./TermsLib.sol";
import {MarginEscrow} from "./MarginEscrow.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWNat} from "./interfaces/IWNat.sol";

/// @title LoanVault — Tributary v1 loan lifecycle (fixed-FLR flavor)
/// @notice Loans are keyed by immutable id in a mapping; no invariant may
///         depend on array position (Debt DAO H-01/H-05). Every lifecycle
///         call asserts the id exists and the loan is in a legal state for
///         that action (H-04). Consent is recorded value-free; funds move
///         only in calls that execute the body (H-03). All outbound value to
///         counterparties goes through pull-withdrawals (M-11). Token
///         movements are measured by balance delta and must match exactly —
///         fee-on-transfer or rebasing assets revert rather than corrupt
///         accounting (M-09).
///
/// The fixed-FLR flavor: the offer states BOTH the USDT0 advanced and the FLR
/// owed — the consented pair IS the locked forward price, so origination
/// needs no oracle. Interest accrual and on-chain dual-cap enforcement land
/// with the PassLedgerOracle build step; until then outstanding == debtFlr.
contract LoanVault {
    enum Status {
        None, // id never used — every guard must reject this
        Offered, // lender posted terms; no borrower consent yet
        Open, // both parties consented; funding + margin arriving
        Drawn, // principal out; repaying
        Triggered, // dead-stream or covenant trigger tripped (oracle step)
        Grace, // 7-day cure window after trigger (oracle step)
        Settled, // margin settled debt + fee; excess returned to borrower
        Repaid, // outstanding reached zero via repayment
        Closed // terminal: cancelled or archived
    }

    struct Loan {
        address borrower;
        address lender;
        uint256 principalUsd; // USDT0 advanced at draw
        uint256 debtFlr; // fixed-FLR debt owed, locked at offer
        uint256 outstandingFlr; // remaining debt; only ever decreases
        uint256 requiredMargin; // WFLR the borrower must escrow before draw
        uint256 benchmarkBps; // lender-alternative benchmark at origination
        uint16 termEpochs;
        bool funded; // lender's USDT0 is in the vault
        MarginEscrow escrow; // per-loan escrow; unset until margin posted
        Status status;
    }

    error LoanDoesNotExist(uint256 id);
    error WrongStatus(uint256 id, Status actual, Status required);
    error NotParty(uint256 id, address caller);
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyFunded(uint256 id);
    error AlreadyMargined(uint256 id);
    error NotReadyToDraw(uint256 id, bool funded, bool margined);
    error InexactTransfer(uint256 expected, uint256 actual);
    error NothingToWithdraw();
    error Reentrancy();

    event LoanOffered(uint256 indexed id, address indexed lender, address indexed borrower);
    event LoanOpened(uint256 indexed id);
    event OfferCancelled(uint256 indexed id);
    event OpenCancelled(uint256 indexed id, address by);
    event LoanFunded(uint256 indexed id);
    event MarginPosted(uint256 indexed id, address escrow);
    event LoanDrawn(uint256 indexed id);
    event Repayment(uint256 indexed id, address from, uint256 applied, uint256 excess);
    event LoanRepaid(uint256 indexed id);
    event Withdrawal(address indexed to, address indexed token, uint256 amount);

    IERC20 public immutable usd; // the loan stablecoin (USDT0)
    IWNat public immutable wnat; // wrapped FLR: margin + repayment asset

    uint256 public nextId = 1; // 0 is never a valid id
    mapping(uint256 => Loan) internal loans;

    /// Pull-withdrawal credits: owed[account][token]. The only way value
    /// leaves the vault to a counterparty.
    mapping(address => mapping(address => uint256)) public owed;

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    modifier inStatus(uint256 id, Status required) {
        if (loans[id].status == Status.None) revert LoanDoesNotExist(id);
        if (loans[id].status != required) revert WrongStatus(id, loans[id].status, required);
        _;
    }

    constructor(IERC20 usd_, IWNat wnat_) {
        if (address(usd_) == address(0) || address(wnat_) == address(0)) revert ZeroAddress();
        usd = usd_;
        wnat = wnat_;
    }

    // ---------------------------------------------------------------- consent

    /// @notice Lender posts terms addressed to one specific borrower.
    ///         Value-free: consent and funds never share a call (H-03).
    ///         The (principalUsd, debtFlr) pair is the locked forward price.
    function offer(
        address borrower,
        uint256 principalUsd,
        uint256 debtFlr,
        uint256 requiredMargin,
        uint256 benchmarkBps,
        uint16 termEpochs
    ) external returns (uint256 id) {
        if (borrower == address(0)) revert ZeroAddress();
        if (principalUsd == 0 || debtFlr == 0 || requiredMargin == 0) revert ZeroAmount();
        id = nextId++;
        loans[id] = Loan({
            borrower: borrower,
            lender: msg.sender,
            principalUsd: principalUsd,
            debtFlr: debtFlr,
            outstandingFlr: debtFlr,
            requiredMargin: requiredMargin,
            benchmarkBps: benchmarkBps,
            termEpochs: termEpochs,
            funded: false,
            escrow: MarginEscrow(address(0)),
            status: Status.Offered
        });
        emit LoanOffered(id, msg.sender, borrower);
    }

    /// @notice Borrower consents to the exact offered terms. Terms are
    ///         immutable per id — any change requires a fresh offer (M-02).
    function accept(uint256 id) external inStatus(id, Status.Offered) {
        if (msg.sender != loans[id].borrower) revert NotParty(id, msg.sender);
        loans[id].status = Status.Open;
        emit LoanOpened(id);
    }

    /// @notice Lender withdraws an un-accepted offer (M-02: offers are
    ///         revocable until consumed).
    function cancelOffer(uint256 id) external inStatus(id, Status.Offered) {
        if (msg.sender != loans[id].lender) revert NotParty(id, msg.sender);
        loans[id].status = Status.Closed;
        emit OfferCancelled(id);
    }

    /// @notice Either party may unwind an Open loan before principal moves —
    ///         no value is at risk yet. Funding and margin are credited back
    ///         to their owners via pull-withdrawal, so neither side's refund
    ///         can be blocked by the other (M-11).
    function cancelOpen(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower && msg.sender != loan.lender) revert NotParty(id, msg.sender);
        loan.status = Status.Closed;
        if (loan.funded) owed[loan.lender][address(usd)] += loan.principalUsd;
        _releaseMargin(loan);
        emit OpenCancelled(id, msg.sender);
    }

    // ---------------------------------------------------------------- funding

    /// @notice Lender deposits the principal. Exact-delta accounting (M-09).
    function fund(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.lender) revert NotParty(id, msg.sender);
        if (loan.funded) revert AlreadyFunded(id);
        loan.funded = true;
        _pullExact(usd, msg.sender, address(this), loan.principalUsd);
        emit LoanFunded(id);
    }

    /// @notice Borrower posts WFLR margin into a fresh per-loan escrow, which
    ///         delegates its whole balance back to the borrower — collateral
    ///         that keeps working.
    function postMargin(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);
        if (address(loan.escrow) != address(0)) revert AlreadyMargined(id);
        MarginEscrow escrow = new MarginEscrow(wnat, loan.borrower);
        loan.escrow = escrow;
        _pullExact(wnat, msg.sender, address(escrow), loan.requiredMargin);
        emit MarginPosted(id, address(escrow));
    }

    /// @notice Borrower takes the principal once funding and margin are both
    ///         in. Direct transfer is safe here: caller is the recipient.
    function draw(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);
        bool margined = address(loan.escrow) != address(0);
        if (!loan.funded || !margined) revert NotReadyToDraw(id, loan.funded, margined);
        loan.status = Status.Drawn;
        _push(usd, loan.borrower, loan.principalUsd);
        emit LoanDrawn(id);
    }

    // -------------------------------------------------------------- repayment

    /// @notice Repay in WFLR. Anyone may pay down a loan (the RewardCollector
    ///         will; a borrower paying early is welcome). The applied amount
    ///         is capped at outstanding BEFORE subtracting — excess is change
    ///         credited to the borrower, never an underflow (H-06). Repaid
    ///         FLR is credited to the lender's pull balance (M-11).
    function repay(uint256 id, uint256 amount) external nonReentrant inStatus(id, Status.Drawn) {
        if (amount == 0) revert ZeroAmount();
        Loan storage loan = loans[id];
        (uint256 applied, uint256 excess) = TermsLib.applyRepayment(loan.outstandingFlr, amount);
        loan.outstandingFlr -= applied;
        owed[loan.lender][address(wnat)] += applied;
        if (excess != 0) owed[loan.borrower][address(wnat)] += excess;
        bool fullyRepaid = loan.outstandingFlr == 0;
        if (fullyRepaid) loan.status = Status.Repaid;
        _pullExact(wnat, msg.sender, address(this), amount);
        emit Repayment(id, msg.sender, applied, excess);
        if (fullyRepaid) {
            _releaseMargin(loan);
            emit LoanRepaid(id);
        }
    }

    /// @notice Pull-withdrawal: the only path value leaves to a counterparty.
    function withdraw(address token) external nonReentrant {
        uint256 amount = owed[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        owed[msg.sender][token] = 0;
        _push(IERC20(token), msg.sender, amount);
        emit Withdrawal(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------ views

    function getLoan(uint256 id) external view returns (Loan memory) {
        if (loans[id].status == Status.None) revert LoanDoesNotExist(id);
        return loans[id];
    }

    // -------------------------------------------------------------- internals

    /// Move margin from the loan's escrow into the borrower's pull balance.
    function _releaseMargin(Loan storage loan) internal {
        if (address(loan.escrow) == address(0)) return;
        uint256 bal = loan.escrow.balance();
        if (bal == 0) return;
        uint256 before = wnat.balanceOf(address(this));
        loan.escrow.releaseToVault(bal);
        uint256 delta = wnat.balanceOf(address(this)) - before;
        if (delta != bal) revert InexactTransfer(bal, delta);
        owed[loan.borrower][address(wnat)] += bal;
    }

    /// transferFrom with exact balance-delta verification (M-09).
    function _pullExact(IERC20 token, address from, address to, uint256 amount) internal {
        uint256 before = token.balanceOf(to);
        if (!token.transferFrom(from, to, amount)) revert InexactTransfer(amount, 0);
        uint256 delta = token.balanceOf(to) - before;
        if (delta != amount) revert InexactTransfer(amount, delta);
    }

    function _push(IERC20 token, address to, uint256 amount) internal {
        if (!token.transfer(to, amount)) revert InexactTransfer(amount, 0);
    }
}
