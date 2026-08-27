// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TermsLib} from "./TermsLib.sol";
import {MarginEscrow} from "./MarginEscrow.sol";
import {RewardCollector} from "./RewardCollector.sol";
import {PassLedgerOracle} from "./PassLedgerOracle.sol";
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
/// owed — the consented pair IS the locked forward price, so no oracle price
/// is needed anywhere: debt, margin, repayment and settlement are all
/// FLR-denominated. The PassLedgerOracle supplies performance data only
/// (trailing rewards, passes, dead streak), never prices.
///
/// Underwriting at accept (the borrower-consent moment), from posted ledger
/// data: >= MIN_SETTLED_EPOCHS history, live stream, and the dual cap —
/// debtFlr <= min(70% x trailing x term, 50% x margin). Trailing, never
/// projected. Interest accrues per posted epoch at the floating pass-rate.
/// Default is a state trigger, never a price: DEAD_EPOCHS_TO_TRIGGER
/// consecutive dead epochs starts a GRACE_PERIOD; any repayment cures;
/// expiry settles exactly debt + accrued + the pre-agreed default fee from
/// margin, and every remaining token returns to the borrower.
contract LoanVault {
    enum Status {
        None, // 0: id never used — every guard must reject this
        Offered, // 1: lender posted terms; no borrower consent yet
        Open, // 2: both parties consented; funding + margin arriving
        Drawn, // 3: principal out; repaying
        Grace, // 4: dead-stream trigger tripped; cure window running
        Settled, // 5: margin settled debt + fee; excess returned to borrower
        Repaid, // 6: outstanding reached zero via repayment
        Closed // 7: terminal: cancelled or archived
    }

    struct Loan {
        address borrower;
        address lender;
        uint256 principalUsd; // USDT0 advanced at draw
        uint256 debtFlr; // fixed-FLR principal, locked at offer
        uint256 outstandingFlr; // remaining debt incl. accrued interest
        uint256 requiredMargin; // WFLR the borrower must escrow before draw
        uint256 defaultFeeFlr; // pre-agreed fixed fee, only ever on settlement
        uint256 benchmarkBps; // lender's passive alternative, annualized
        uint64 lastAccrualEpoch; // oracle epoch interest is accrued through
        uint64 curedAtEpoch; // oracle epoch of the latest grace cure
        uint64 graceEndsAt; // timestamp the cure window closes
        uint16 termEpochs;
        bool funded; // lender's USDT0 is in the vault
        MarginEscrow escrow; // per-loan escrow; unset until margin posted
        RewardCollector collector; // per-loan claim target, deployed at accept
        Status status;
    }

    uint32 public constant MIN_SETTLED_EPOCHS = 10;
    uint32 public constant DEAD_EPOCHS_TO_TRIGGER = 4;
    uint64 public constant GRACE_PERIOD = 7 days;

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
    error InsufficientHistory(uint32 settled, uint32 required);
    error StreamNotLive(uint32 deadStreak);
    error ExceedsCreditLine(uint256 debtFlr, uint256 line);
    error TriggerNotMet(uint256 id);
    error GraceNotExpired(uint256 id, uint64 endsAt);

    event LoanOffered(uint256 indexed id, address indexed lender, address indexed borrower);
    event LoanOpened(uint256 indexed id, address collector);
    event OfferCancelled(uint256 indexed id);
    event OpenCancelled(uint256 indexed id, address by);
    event LoanFunded(uint256 indexed id);
    event MarginPosted(uint256 indexed id, address escrow);
    event LoanDrawn(uint256 indexed id);
    event InterestAccrued(uint256 indexed id, uint256 interest, uint64 throughEpoch);
    event Repayment(uint256 indexed id, address from, uint256 applied, uint256 excess);
    event LoanRepaid(uint256 indexed id);
    event GraceStarted(uint256 indexed id, uint64 endsAt);
    event GraceCured(uint256 indexed id);
    event LoanSettled(uint256 indexed id, uint256 recovered, uint256 shortfall, uint256 returnedToBorrower);
    event Withdrawal(address indexed to, address indexed token, uint256 amount);

    IERC20 public immutable usd; // the loan stablecoin (USDT0)
    IWNat public immutable wnat; // wrapped FLR: margin + repayment asset
    PassLedgerOracle public immutable oracle;

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

    constructor(IERC20 usd_, IWNat wnat_, PassLedgerOracle oracle_) {
        if (address(usd_) == address(0) || address(wnat_) == address(0) || address(oracle_) == address(0)) {
            revert ZeroAddress();
        }
        usd = usd_;
        wnat = wnat_;
        oracle = oracle_;
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
        uint256 defaultFeeFlr,
        uint256 benchmarkBps,
        uint16 termEpochs
    ) external returns (uint256 id) {
        if (borrower == address(0)) revert ZeroAddress();
        if (principalUsd == 0 || debtFlr == 0 || requiredMargin == 0 || termEpochs == 0) revert ZeroAmount();
        id = nextId++;
        Loan storage loan = loans[id];
        loan.borrower = borrower;
        loan.lender = msg.sender;
        loan.principalUsd = principalUsd;
        loan.debtFlr = debtFlr;
        loan.outstandingFlr = debtFlr;
        loan.requiredMargin = requiredMargin;
        loan.defaultFeeFlr = defaultFeeFlr;
        loan.benchmarkBps = benchmarkBps;
        loan.termEpochs = termEpochs;
        loan.status = Status.Offered;
        emit LoanOffered(id, msg.sender, borrower);
    }

    /// @notice Borrower consents to the exact offered terms — and this is the
    ///         underwriting moment: the loan must clear the posted ledger
    ///         (history, live stream, dual cap) HERE, with the borrower's
    ///         consent and the ledger snapshot in the same breath. Terms are
    ///         immutable per id — any change requires a fresh offer (M-02).
    function accept(uint256 id) external inStatus(id, Status.Offered) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);

        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        if (rec.settledEpochs < MIN_SETTLED_EPOCHS) {
            revert InsufficientHistory(rec.settledEpochs, MIN_SETTLED_EPOCHS);
        }
        if (rec.deadStreak != 0) revert StreamNotLive(rec.deadStreak);
        uint256 line = TermsLib.creditLine(rec.trailingRewardPerEpoch, loan.termEpochs, loan.requiredMargin);
        if (loan.debtFlr > line) revert ExceedsCreditLine(loan.debtFlr, line);

        loan.status = Status.Open;
        loan.collector = new RewardCollector(wnat, id);
        emit LoanOpened(id, address(loan.collector));
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
    ///         Interest starts accruing from the ledger epoch current at draw.
    function draw(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);
        bool margined = address(loan.escrow) != address(0);
        if (!loan.funded || !margined) revert NotReadyToDraw(id, loan.funded, margined);
        loan.status = Status.Drawn;
        loan.lastAccrualEpoch = oracle.latest(loan.borrower).epochId;
        _push(usd, loan.borrower, loan.principalUsd);
        emit LoanDrawn(id);
    }

    // ---------------------------------------------------------------- accrual

    /// @notice Accrue interest through the latest posted epoch at the
    ///         floating pass-rate: benchmark + 4pts − 1pt per pass held,
    ///         floored at benchmark + 1pt. The protocol's own incentive
    ///         system is the credit spread. Callable by anyone; every
    ///         state-changing entry accrues first.
    function accrue(uint256 id) public {
        Loan storage loan = loans[id];
        if (loan.status != Status.Drawn && loan.status != Status.Grace) return;
        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        if (rec.epochId <= loan.lastAccrualEpoch) return;
        uint256 epochs = rec.epochId - loan.lastAccrualEpoch;
        uint256 rate = TermsLib.rateBps(loan.benchmarkBps, rec.passCount);
        uint256 interest = TermsLib.epochInterest(loan.outstandingFlr, rate, epochs);
        loan.outstandingFlr += interest;
        loan.lastAccrualEpoch = rec.epochId;
        emit InterestAccrued(id, interest, rec.epochId);
    }

    // -------------------------------------------------------------- repayment

    /// @notice Repay in WFLR. Anyone may pay down a loan (the RewardCollector
    ///         does; a borrower paying early is welcome). The applied amount
    ///         is capped at outstanding BEFORE subtracting — excess is change
    ///         credited to the borrower, never an underflow (H-06). Repaid
    ///         FLR is credited to the lender's pull balance (M-11). A payment
    ///         during Grace cures the trigger.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        Loan storage loan = loans[id];
        if (loan.status == Status.None) revert LoanDoesNotExist(id);
        if (loan.status != Status.Drawn && loan.status != Status.Grace) {
            revert WrongStatus(id, loan.status, Status.Drawn);
        }
        if (amount == 0) revert ZeroAmount();
        accrue(id);

        (uint256 applied, uint256 excess) = TermsLib.applyRepayment(loan.outstandingFlr, amount);
        loan.outstandingFlr -= applied;
        owed[loan.lender][address(wnat)] += applied;
        if (excess != 0) owed[loan.borrower][address(wnat)] += excess;

        bool wasGrace = loan.status == Status.Grace;
        bool fullyRepaid = loan.outstandingFlr == 0;
        if (fullyRepaid) {
            loan.status = Status.Repaid;
        } else if (wasGrace) {
            // any payment cures: the borrower is not "refusing to pay"
            loan.status = Status.Drawn;
            loan.curedAtEpoch = oracle.latest(loan.borrower).epochId;
            emit GraceCured(id);
        }

        _pullExact(wnat, msg.sender, address(this), amount);
        emit Repayment(id, msg.sender, applied, excess);
        if (fullyRepaid) {
            _releaseMargin(loan);
            emit LoanRepaid(id);
        }
    }

    // ---------------------------------------------------------------- default

    /// @notice Anyone may start the cure window once the posted ledger shows
    ///         a genuinely dead validator: DEAD_EPOCHS_TO_TRIGGER consecutive
    ///         dead epochs. No liquidation price exists anywhere in this
    ///         contract — a zero-reward epoch alone does nothing but extend
    ///         the payoff date. After a cure, at least one NEW epoch must be
    ///         posted before the trigger can trip again.
    function trip(uint256 id) external inStatus(id, Status.Drawn) {
        Loan storage loan = loans[id];
        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        bool dead = rec.deadStreak >= DEAD_EPOCHS_TO_TRIGGER;
        bool newEpochSinceCure = rec.epochId > loan.curedAtEpoch;
        if (!dead || !newEpochSinceCure) revert TriggerNotMet(id);
        accrue(id);
        loan.status = Status.Grace;
        loan.graceEndsAt = uint64(block.timestamp) + GRACE_PERIOD;
        emit GraceStarted(id, loan.graceEndsAt);
    }

    /// @notice Settlement, not a jackpot: after the grace window expires
    ///         uncured, the margin settles exactly outstanding + the
    ///         pre-agreed default fee. The lender recovers up to the margin's
    ///         value, never more; EVERY remaining token returns to the
    ///         borrower. Callable by anyone once due.
    function settle(uint256 id) external nonReentrant inStatus(id, Status.Grace) {
        Loan storage loan = loans[id];
        if (block.timestamp < loan.graceEndsAt) revert GraceNotExpired(id, loan.graceEndsAt);
        accrue(id);

        uint256 due = loan.outstandingFlr + loan.defaultFeeFlr;
        uint256 marginBal = address(loan.escrow) == address(0) ? 0 : loan.escrow.balance();
        uint256 recovered = due < marginBal ? due : marginBal;
        uint256 backToBorrower = marginBal - recovered;
        uint256 shortfall = due - recovered;

        loan.status = Status.Settled;
        loan.outstandingFlr = 0;

        if (marginBal != 0) {
            uint256 before = wnat.balanceOf(address(this));
            loan.escrow.releaseToVault(marginBal);
            uint256 delta = wnat.balanceOf(address(this)) - before;
            if (delta != marginBal) revert InexactTransfer(marginBal, delta);
        }
        owed[loan.lender][address(wnat)] += recovered;
        if (backToBorrower != 0) owed[loan.borrower][address(wnat)] += backToBorrower;
        emit LoanSettled(id, recovered, shortfall, backToBorrower);
    }

    // ------------------------------------------------------------ withdrawals

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

    /// @dev Raw status for the RewardCollector's routing decision; returns 0
    ///      (None) rather than reverting so the collector's guard stays simple.
    function statusOf(uint256 id) external view returns (uint8) {
        return uint8(loans[id].status);
    }

    function borrowerOf(uint256 id) external view returns (address) {
        return loans[id].borrower;
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
