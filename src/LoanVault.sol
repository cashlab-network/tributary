// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TermsLib} from "./TermsLib.sol";
import {MarginEscrow} from "./MarginEscrow.sol";
import {RewardCollector} from "./RewardCollector.sol";
import {PassLedgerOracle} from "./PassLedgerOracle.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWNat} from "./interfaces/IWNat.sol";
import {IFtsoV2} from "./interfaces/IFtsoV2.sol";

/// @title LoanVault — Tributary loan lifecycle, both flavors
/// @notice Loans are keyed by immutable id in a mapping; no invariant may
///         depend on array position (Debt DAO H-01/H-05). Every lifecycle
///         call asserts the id exists and the loan is in a legal state
///         (H-04). Consent is value-free (H-03). Counterparty payouts are
///         pull-withdrawals only (M-11). Token movements are verified by
///         exact balance delta (M-09).
///
/// TWO FLAVORS, one vault:
///  - fixed-FLR: the borrower owes a fixed number of FLR. The consented
///    (principalUsd, debtFlr) pair IS the locked forward price — the FTSO is
///    only consulted (when a band is configured) to sanity-check that pair
///    at accept, so a fat-fingered price cannot be consented silently.
///  - fixed-dollar: the borrower owes a dollar amount, repaid in FLR valued
///    at the FTSO's FLR/USD price at each repayment. Borrower keeps all
///    upside (rising price -> fewer coins per dollar); lender prices the cap
///    into a higher rate. No caller-supplied trade data anywhere — the FTSO
///    is the only price source (M-04 stays deleted).
///
/// Policy (history minimum, dead-epoch trigger, grace length) and the reward
/// epoch length are PER-CHAIN configuration set at deploy — chain facts are
/// read from the chain, policy is chosen consciously, nothing is assumed.
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

    struct Config {
        IERC20 usd; // the loan stablecoin (USDT0, 6 decimals)
        IWNat wnat; // wrapped FLR: margin + repayment asset
        PassLedgerOracle oracle;
        address claimSetupManager; // zero in pure unit tests
        address keeperExecutor; // executor escrows authorize for claims
        uint256 epochDurationSeconds; // chain fact: FlareSystemsManager value
        IFtsoV2 ftso; // FLR/USD source (zero disables all price logic)
        bytes21 flrUsdFeedId;
        uint16 maxPriceDeviationBps; // fixed-FLR pair sanity band; 0 = off
        uint32 minSettledEpochs; // policy: history required to underwrite
        uint32 deadEpochsToTrigger; // policy: consecutive dead epochs
        uint64 gracePeriod; // policy: cure window length
        uint64 maxPriceAge; // staleness bound on FTSO reads
    }

    struct Loan {
        address borrower;
        address lender;
        bool fixedDollar; // flavor: false = fixed-FLR, true = fixed-dollar
        uint256 principalUsd; // USDT0 advanced at draw (6 decimals)
        uint256 debt; // fixed at offer: FLR wei, or USD 6dp (by flavor)
        uint256 outstanding; // remaining debt incl. accrued interest
        uint256 requiredMargin; // WFLR the borrower must escrow before draw
        uint256 defaultFee; // pre-agreed, in the debt's denomination
        uint256 benchmarkBps; // lender's passive alternative, annualized
        uint64 lastAccrualEpoch;
        uint64 curedAtEpoch;
        uint64 graceEndsAt;
        uint16 termEpochs;
        bool funded;
        MarginEscrow escrow;
        RewardCollector collector;
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
    error InsufficientHistory(uint32 settled, uint32 required);
    error StreamNotLive(uint32 deadStreak);
    error ExceedsCreditLine(uint256 debt, uint256 line);
    error TriggerNotMet(uint256 id);
    error GraceNotExpired(uint256 id, uint64 endsAt);
    error PriceUnavailable(); // no FTSO configured for a flavor that needs it
    error StalePrice(uint64 timestamp);
    error PriceOutOfBand(uint256 implied, uint256 oracle);

    event LoanOffered(uint256 indexed id, address indexed lender, address indexed borrower, bool fixedDollar);
    event LoanOpened(uint256 indexed id, address collector);
    event OfferCancelled(uint256 indexed id);
    event OpenCancelled(uint256 indexed id, address by);
    event LoanFunded(uint256 indexed id);
    event MarginPosted(uint256 indexed id, address escrow);
    event LoanDrawn(uint256 indexed id);
    event InterestAccrued(uint256 indexed id, uint256 interest, uint64 throughEpoch);
    event Repayment(uint256 indexed id, address from, uint256 appliedDebt, uint256 lenderFlr, uint256 excessFlr);
    event LoanRepaid(uint256 indexed id);
    event GraceStarted(uint256 indexed id, uint64 endsAt);
    event GraceCured(uint256 indexed id);
    event LoanSettled(uint256 indexed id, uint256 recoveredFlr, uint256 shortfallFlr, uint256 returnedToBorrower);
    event Withdrawal(address indexed to, address indexed token, uint256 amount);

    IERC20 public immutable usd;
    IWNat public immutable wnat;
    PassLedgerOracle public immutable oracle;
    address public immutable claimSetupManager;
    address public immutable keeperExecutor;
    uint256 public immutable epochDurationSeconds;
    IFtsoV2 public immutable ftso;
    bytes21 public immutable flrUsdFeedId;
    uint16 public immutable maxPriceDeviationBps;
    uint32 public immutable minSettledEpochs;
    uint32 public immutable deadEpochsToTrigger;
    uint64 public immutable gracePeriod;
    uint64 public immutable maxPriceAge;

    uint256 public nextId = 1; // 0 is never a valid id
    mapping(uint256 => Loan) internal loans;

    /// Pull-withdrawal credits: owed[account][token].
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

    constructor(Config memory cfg) {
        if (address(cfg.usd) == address(0) || address(cfg.wnat) == address(0) || address(cfg.oracle) == address(0)) {
            revert ZeroAddress();
        }
        if (cfg.epochDurationSeconds == 0 || cfg.deadEpochsToTrigger == 0) revert ZeroAmount();
        usd = cfg.usd;
        wnat = cfg.wnat;
        oracle = cfg.oracle;
        claimSetupManager = cfg.claimSetupManager;
        keeperExecutor = cfg.keeperExecutor;
        epochDurationSeconds = cfg.epochDurationSeconds;
        ftso = cfg.ftso;
        flrUsdFeedId = cfg.flrUsdFeedId;
        maxPriceDeviationBps = cfg.maxPriceDeviationBps;
        minSettledEpochs = cfg.minSettledEpochs;
        deadEpochsToTrigger = cfg.deadEpochsToTrigger;
        gracePeriod = cfg.gracePeriod;
        maxPriceAge = cfg.maxPriceAge == 0 ? 1 hours : cfg.maxPriceAge;
    }

    // ---------------------------------------------------------------- consent

    /// @notice Lender posts terms for one specific borrower. Value-free
    ///         (H-03). `debt` is FLR wei (fixed-FLR) or USD 6dp
    ///         (fixed-dollar); `defaultFee` shares the debt's denomination.
    function offer(
        address borrower,
        bool fixedDollar,
        uint256 principalUsd,
        uint256 debt,
        uint256 requiredMargin,
        uint256 defaultFee,
        uint256 benchmarkBps,
        uint16 termEpochs
    ) external returns (uint256 id) {
        if (borrower == address(0)) revert ZeroAddress();
        if (principalUsd == 0 || debt == 0 || requiredMargin == 0 || termEpochs == 0) revert ZeroAmount();
        if (fixedDollar && address(ftso) == address(0)) revert PriceUnavailable();
        id = nextId++;
        Loan storage loan = loans[id];
        loan.borrower = borrower;
        loan.lender = msg.sender;
        loan.fixedDollar = fixedDollar;
        loan.principalUsd = principalUsd;
        loan.debt = debt;
        loan.outstanding = debt;
        loan.requiredMargin = requiredMargin;
        loan.defaultFee = defaultFee;
        loan.benchmarkBps = benchmarkBps;
        loan.termEpochs = termEpochs;
        loan.status = Status.Offered;
        emit LoanOffered(id, msg.sender, borrower, fixedDollar);
    }

    /// @notice Borrower consents — and this is the underwriting moment:
    ///         history, live stream, dual cap, and (where configured) the
    ///         price sanity checks all pass HERE or the loan never opens.
    function accept(uint256 id) external inStatus(id, Status.Offered) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);

        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        if (rec.settledEpochs < minSettledEpochs) revert InsufficientHistory(rec.settledEpochs, minSettledEpochs);
        if (rec.deadStreak != 0) revert StreamNotLive(rec.deadStreak);

        uint256 lineFlr = TermsLib.creditLine(rec.trailingRewardPerEpoch, loan.termEpochs, loan.requiredMargin);
        if (loan.fixedDollar) {
            // debt is USD: value the FLR-denominated line at the oracle price
            (uint256 v, uint8 d) = _price();
            uint256 lineUsd = TermsLib.flrToUsd6(lineFlr, v, d);
            if (loan.debt > lineUsd) revert ExceedsCreditLine(loan.debt, lineUsd);
        } else {
            if (loan.debt > lineFlr) revert ExceedsCreditLine(loan.debt, lineFlr);
            // pair sanity band (G13): the consented forward price must sit
            // within maxPriceDeviationBps of the oracle, when configured
            if (maxPriceDeviationBps != 0 && address(ftso) != address(0)) {
                (uint256 v, uint8 d) = _price();
                uint256 implied = (loan.principalUsd * 10 ** d * 1e12) / loan.debt;
                uint256 diff = implied > v ? implied - v : v - implied;
                if (diff * 10_000 > uint256(v) * maxPriceDeviationBps) revert PriceOutOfBand(implied, v);
            }
        }

        loan.status = Status.Open;
        loan.collector = new RewardCollector(wnat, id);
        emit LoanOpened(id, address(loan.collector));
    }

    /// @notice Lender withdraws an un-accepted offer (M-02).
    function cancelOffer(uint256 id) external inStatus(id, Status.Offered) {
        if (msg.sender != loans[id].lender) revert NotParty(id, msg.sender);
        loans[id].status = Status.Closed;
        emit OfferCancelled(id);
    }

    /// @notice Either party unwinds an Open loan before principal moves;
    ///         refunds land as pull-credits so neither can block the other.
    function cancelOpen(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower && msg.sender != loan.lender) revert NotParty(id, msg.sender);
        loan.status = Status.Closed;
        if (loan.funded) owed[loan.lender][address(usd)] += loan.principalUsd;
        _releaseMargin(loan);
        emit OpenCancelled(id, msg.sender);
    }

    // ---------------------------------------------------------------- funding

    function fund(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.lender) revert NotParty(id, msg.sender);
        if (loan.funded) revert AlreadyFunded(id);
        loan.funded = true;
        _pullExact(usd, msg.sender, address(this), loan.principalUsd);
        emit LoanFunded(id);
    }

    function postMargin(uint256 id) external nonReentrant inStatus(id, Status.Open) {
        Loan storage loan = loans[id];
        if (msg.sender != loan.borrower) revert NotParty(id, msg.sender);
        if (address(loan.escrow) != address(0)) revert AlreadyMargined(id);
        MarginEscrow escrow = new MarginEscrow(wnat, loan.borrower, claimSetupManager, keeperExecutor);
        loan.escrow = escrow;
        _pullExact(wnat, msg.sender, address(escrow), loan.requiredMargin);
        emit MarginPosted(id, address(escrow));
    }

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
    ///         floating pass-rate. Unit-agnostic: accrues on the outstanding
    ///         balance in the loan's own denomination.
    function accrue(uint256 id) public {
        Loan storage loan = loans[id];
        if (loan.status != Status.Drawn && loan.status != Status.Grace) return;
        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        if (rec.epochId <= loan.lastAccrualEpoch) return;
        uint256 epochs = rec.epochId - loan.lastAccrualEpoch;
        uint256 rate = TermsLib.rateBps(loan.benchmarkBps, rec.passCount);
        uint256 interest = TermsLib.epochInterest(loan.outstanding, rate, epochs, epochDurationSeconds);
        loan.outstanding += interest;
        loan.lastAccrualEpoch = rec.epochId;
        emit InterestAccrued(id, interest, rec.epochId);
    }

    // -------------------------------------------------------------- repayment

    /// @notice Repay in WFLR (anyone may pay). Fixed-FLR: the amount is the
    ///         payment. Fixed-dollar: the amount is VALUED at the FTSO price
    ///         and credited against the dollar debt — borrower keeps the
    ///         upside, price falls deliver more coins per dollar. Either
    ///         way: capped before subtracting (H-06), excess is change to
    ///         the borrower, lender is paid via pull-credit (M-11), and a
    ///         payment during Grace cures the trigger.
    function repay(uint256 id, uint256 amount) external nonReentrant {
        Loan storage loan = loans[id];
        if (loan.status == Status.None) revert LoanDoesNotExist(id);
        if (loan.status != Status.Drawn && loan.status != Status.Grace) {
            revert WrongStatus(id, loan.status, Status.Drawn);
        }
        if (amount == 0) revert ZeroAmount();
        accrue(id);

        uint256 appliedDebt; // in the loan's denomination
        uint256 lenderFlr;
        uint256 excessFlr;
        if (loan.fixedDollar) {
            (uint256 v, uint8 d) = _price();
            uint256 usdValue = TermsLib.flrToUsd6(amount, v, d);
            if (usdValue < loan.outstanding) {
                appliedDebt = usdValue;
                lenderFlr = amount;
            } else {
                appliedDebt = loan.outstanding;
                lenderFlr = TermsLib.usd6ToFlrCeil(appliedDebt, v, d);
                if (lenderFlr > amount) lenderFlr = amount; // ceil never exceeds delivery
                excessFlr = amount - lenderFlr;
            }
        } else {
            uint256 excessDebt;
            (appliedDebt, excessDebt) = TermsLib.applyRepayment(loan.outstanding, amount);
            lenderFlr = appliedDebt;
            excessFlr = excessDebt;
        }

        loan.outstanding -= appliedDebt;
        owed[loan.lender][address(wnat)] += lenderFlr;
        if (excessFlr != 0) owed[loan.borrower][address(wnat)] += excessFlr;

        bool wasGrace = loan.status == Status.Grace;
        bool fullyRepaid = loan.outstanding == 0;
        if (fullyRepaid) {
            loan.status = Status.Repaid;
        } else if (wasGrace) {
            loan.status = Status.Drawn;
            loan.curedAtEpoch = oracle.latest(loan.borrower).epochId;
            emit GraceCured(id);
        }

        _pullExact(wnat, msg.sender, address(this), amount);
        emit Repayment(id, msg.sender, appliedDebt, lenderFlr, excessFlr);
        if (fullyRepaid) {
            _releaseMargin(loan);
            emit LoanRepaid(id);
        }
    }

    // ---------------------------------------------------------------- default

    /// @notice State trigger, never a price: deadEpochsToTrigger consecutive
    ///         dead epochs on the posted ledger. After a cure, a NEW epoch
    ///         must post before it can trip again.
    function trip(uint256 id) external inStatus(id, Status.Drawn) {
        Loan storage loan = loans[id];
        PassLedgerOracle.Record memory rec = oracle.latest(loan.borrower);
        bool dead = rec.deadStreak >= deadEpochsToTrigger;
        bool newEpochSinceCure = rec.epochId > loan.curedAtEpoch;
        if (!dead || !newEpochSinceCure) revert TriggerNotMet(id);
        accrue(id);
        loan.status = Status.Grace;
        loan.graceEndsAt = uint64(block.timestamp) + gracePeriod;
        emit GraceStarted(id, loan.graceEndsAt);
    }

    /// @notice Settlement, not a jackpot: exactly debt + fee (valued at the
    ///         FTSO for fixed-dollar loans), everything else back to the
    ///         borrower. Lenders get recovery up to the margin, never more.
    function settle(uint256 id) external nonReentrant inStatus(id, Status.Grace) {
        Loan storage loan = loans[id];
        if (block.timestamp < loan.graceEndsAt) revert GraceNotExpired(id, loan.graceEndsAt);
        accrue(id);

        uint256 due = loan.outstanding + loan.defaultFee;
        uint256 dueFlr;
        if (loan.fixedDollar) {
            (uint256 v, uint8 d) = _price();
            dueFlr = TermsLib.usd6ToFlrCeil(due, v, d);
        } else {
            dueFlr = due;
        }
        uint256 marginBal = address(loan.escrow) == address(0) ? 0 : loan.escrow.balance();
        uint256 recovered = dueFlr < marginBal ? dueFlr : marginBal;
        uint256 backToBorrower = marginBal - recovered;
        uint256 shortfall = dueFlr - recovered;

        loan.status = Status.Settled;
        loan.outstanding = 0;

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

    function statusOf(uint256 id) external view returns (uint8) {
        return uint8(loans[id].status);
    }

    function borrowerOf(uint256 id) external view returns (address) {
        return loans[id].borrower;
    }

    // -------------------------------------------------------------- internals

    /// Fresh FLR/USD from the FTSO, with a staleness bound. The FTSO is the
    /// ONLY price source in the system (M-04: no caller-supplied pricing).
    function _price() internal returns (uint256 value, uint8 decimals) {
        if (address(ftso) == address(0)) revert PriceUnavailable();
        (uint256 v, int8 d, uint64 ts) = ftso.getFeedById(flrUsdFeedId);
        if (v == 0 || d < 0 || d > 18) revert PriceUnavailable();
        if (ts + maxPriceAge < block.timestamp) revert StalePrice(ts);
        return (v, uint8(d));
    }

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
