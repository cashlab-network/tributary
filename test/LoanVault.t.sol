// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {MarginEscrow} from "../src/MarginEscrow.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {TermsLib} from "../src/TermsLib.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {MockERC20, MockWNat, MockCSM, MockFtso, FeeOnTransferToken} from "./mocks/Tokens.sol";

contract LoanVaultTestBase is Test {
    LoanVault vault;
    PassLedgerOracle oracle;
    MockERC20 usd;
    MockWNat wnat;
    MockCSM csm;
    MockFtso ftso;

    // Mainnet epoch length for unit tests; the chain value is read from
    // FlareSystemsManager at deploy time (Coston2: 21,600s).
    uint256 constant EPOCH_SECONDS = 302_400;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address stranger = makeAddr("stranger");
    address keeper = makeAddr("keeperExecutor");

    uint256 constant PRINCIPAL_USD = 1_000e6; // 1,000 USDT0
    uint256 constant DEBT_FLR = 50_000 ether; // locked forward price
    uint256 constant MARGIN = 100_000 ether; // 2x debt in WFLR
    uint256 constant DEFAULT_FEE = 500 ether;
    uint256 constant BENCHMARK_BPS = 500; // 5% staking-yield benchmark
    uint16 constant TERM_EPOCHS = 4;
    uint192 constant TRAILING = 20_000 ether; // per-epoch trailing rewards

    uint64 epoch = 100; // current ledger epoch, advanced by helpers

    function setUp() public virtual {
        usd = new MockERC20("USDT0");
        wnat = new MockWNat();
        csm = new MockCSM();
        ftso = new MockFtso();
        oracle = new PassLedgerOracle(address(this), IFlareContractRegistry(address(0)), 8);
        vault = new LoanVault(_config(0)); // band off in the base suite

        usd.mint(lender, PRINCIPAL_USD);
        wnat.mint(borrower, MARGIN + DEBT_FLR * 2);
        vm.prank(lender);
        usd.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        wnat.approve(address(vault), type(uint256).max);

        _postAlive(); // healthy starting record: 3 passes, 20 settled epochs
    }

    function _config(uint16 bandBps) internal view returns (LoanVault.Config memory) {
        return LoanVault.Config({
            usd: IERC20(address(usd)),
            wnat: IWNat(address(wnat)),
            oracle: oracle,
            claimSetupManager: address(csm),
            keeperExecutor: keeper,
            epochDurationSeconds: EPOCH_SECONDS,
            ftso: IFtsoV2(address(ftso)),
            flrUsdFeedId: bytes21(uint168(1)),
            maxPriceDeviationBps: bandBps,
            minSettledEpochs: 10,
            deadEpochsToTrigger: 4,
            gracePeriod: 7 days,
            maxPriceAge: 1 hours,
            requireProvenTrailing: false
        });
    }

    function _postAlive() internal {
        oracle.post(borrower, ++epoch, TRAILING, 3, 20, true);
    }

    function _postDead() internal {
        oracle.post(borrower, ++epoch, TRAILING, 3, 20, false);
    }

    function _offer() internal returns (uint256 id) {
        vm.prank(lender);
        id = vault.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
    }

    function _openAndDraw() internal returns (uint256 id) {
        return _openAndDrawTerm(TERM_EPOCHS);
    }

    function _openAndDrawTerm(uint16 term) internal returns (uint256 id) {
        vm.prank(lender);
        id = vault.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, term);
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();
    }
}

contract LoanVaultLifecycleTest is LoanVaultTestBase {
    // --- the H-04 failing case: bogus ids must revert everywhere ---

    function test_lifecycle_bogusIdRevertsEverywhere() public {
        bytes memory err = abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 0);
        vm.expectRevert(err);
        vault.accept(0);
        vm.expectRevert(err);
        vault.cancelOffer(0);
        vm.expectRevert(err);
        vault.cancelOpen(0);
        vm.expectRevert(err);
        vault.fund(0);
        vm.expectRevert(err);
        vault.postMargin(0);
        vm.expectRevert(err);
        vault.draw(0);
        vm.expectRevert(err);
        vault.repay(0, 1);
        vm.expectRevert(err);
        vault.trip(0);
        vm.expectRevert(err);
        vault.settle(0);
        vm.expectRevert(err);
        vault.getLoan(0);
    }

    // --- underwriting at accept: the ledger decides ---

    function test_accept_withoutHistoryReverts() public {
        address newcomer = makeAddr("newcomer");
        vm.prank(lender);
        uint256 id = vault.offer(newcomer, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.InsufficientHistory.selector, 0, 10));
        vm.prank(newcomer);
        vault.accept(id);
    }

    function test_accept_deadStreamReverts() public {
        uint256 id = _offer();
        _postDead();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.StreamNotLive.selector, 1));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_accept_debtAboveDualCapReverts() public {
        // stream cap binds: 70% * 20k * 4 = 56k; ask 60k
        vm.prank(lender);
        uint256 id =
            vault.offer(borrower, false, PRINCIPAL_USD, 60_000 ether, 1_000_000 ether, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 60_000 ether, 56_000 ether));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_accept_marginCapBinds() public {
        // margin cap binds: 50% * 80k = 40k line; ask 45k (stream cap 56k ok)
        vm.prank(lender);
        uint256 id =
            vault.offer(borrower, false, PRINCIPAL_USD, 45_000 ether, 80_000 ether, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 45_000 ether, 40_000 ether));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_accept_deploysCollector() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        RewardCollector collector = vault.getLoan(id).collector;
        assertEq(collector.loanId(), id);
        assertEq(address(collector.vault()), address(vault));
    }

    // --- G11: lender-position transfer (secondary market) ---

    function test_transferLender_futureRepaymentsGoToNewLender() public {
        uint256 id = _openAndDraw();
        address buyer = makeAddr("positionBuyer");
        vm.prank(lender);
        vault.transferLender(id, buyer);
        assertEq(vault.getLoan(id).lender, buyer);
        // repay -> credit goes to the NEW lender, not the old one
        vm.prank(borrower);
        vault.repay(id, 10_000 ether);
        assertEq(vault.owed(buyer, address(wnat)), 10_000 ether);
        assertEq(vault.owed(lender, address(wnat)), 0);
    }

    function test_transferLender_keepsAlreadyEarned() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, 10_000 ether); // old lender earns this
        address buyer = makeAddr("positionBuyer");
        vm.prank(lender);
        vault.transferLender(id, buyer);
        vm.prank(borrower);
        vault.repay(id, 10_000 ether); // new lender earns this
        assertEq(vault.owed(lender, address(wnat)), 10_000 ether); // kept
        assertEq(vault.owed(buyer, address(wnat)), 10_000 ether);
    }

    function test_transferLender_byNonLenderReverts() public {
        uint256 id = _openAndDraw();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotParty.selector, id, stranger));
        vm.prank(stranger);
        vault.transferLender(id, stranger);
    }

    function test_transferLender_afterRepaidReverts() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR);
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.WrongStatus.selector, id, LoanVault.Status.Repaid, LoanVault.Status.Drawn)
        );
        vm.prank(lender);
        vault.transferLender(id, makeAddr("buyer"));
    }

    function test_transferLender_zeroReverts() public {
        uint256 id = _openAndDraw();
        vm.expectRevert(LoanVault.ZeroAddress.selector);
        vm.prank(lender);
        vault.transferLender(id, address(0));
    }

    // --- consent: party-scoped, revocable until consumed ---

    function test_accept_byNonBorrowerReverts() public {
        uint256 id = _offer();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotParty.selector, id, stranger));
        vm.prank(stranger);
        vault.accept(id);
    }

    function test_cancelOffer_afterAcceptReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.WrongStatus.selector, id, LoanVault.Status.Open, LoanVault.Status.Offered)
        );
        vm.prank(lender);
        vault.cancelOffer(id);
    }

    // --- funding + margin + draw gating ---

    function test_fund_twiceReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.startPrank(lender);
        vault.fund(id);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.AlreadyFunded.selector, id));
        vault.fund(id);
        vm.stopPrank();
    }

    function test_draw_withoutBothLegsReverts() public {
        uint256 id = _offer();
        vm.startPrank(borrower);
        vault.accept(id);
        vault.postMargin(id);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotReadyToDraw.selector, id, false, true));
        vault.draw(id);
        vm.stopPrank();
    }

    function test_draw_paysBorrowerExactly() public {
        _openAndDraw();
        assertEq(usd.balanceOf(borrower), PRINCIPAL_USD);
        assertEq(usd.balanceOf(address(vault)), 0);
    }

    function test_postMargin_escrowEnrollsClaimSetup() public {
        // delegation rewards accrue to the ESCROW (the WNat holder); without
        // claim setup they would expire unclaimable. Escrow must self-enroll:
        // keeper executes, borrower is the sole recipient.
        uint256 id = _offer();
        vm.startPrank(borrower);
        vault.accept(id);
        vault.postMargin(id);
        vm.stopPrank();
        address escrow = address(vault.getLoan(id).escrow);
        assertEq(csm.executorOf(escrow), keeper);
        assertEq(csm.recipientOf(escrow), borrower);
    }

    function test_postMargin_escrowDelegatesBackToBorrower() public {
        uint256 id = _offer();
        vm.startPrank(borrower);
        vault.accept(id);
        vault.postMargin(id);
        vm.stopPrank();
        address escrow = address(vault.getLoan(id).escrow);
        assertEq(wnat.balanceOf(escrow), MARGIN);
        assertEq(wnat.delegatee(escrow), borrower);
        assertEq(wnat.delegatedBips(escrow), 10_000);
    }

    function test_cancelOpen_refundsBothSidesViaPull() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.prank(borrower);
        vault.postMargin(id);

        vm.prank(lender);
        vault.cancelOpen(id);

        assertEq(vault.owed(lender, address(usd)), PRINCIPAL_USD);
        assertEq(vault.owed(borrower, address(wnat)), MARGIN);
    }

    // --- repayment ---

    function test_repay_partialThenFull_noEpochAdvance() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, 20_000 ether);
        assertEq(vault.getLoan(id).outstanding, 30_000 ether);

        vm.prank(borrower);
        vault.repay(id, 30_000 ether);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        assertEq(vault.owed(lender, address(wnat)), DEBT_FLR);
        assertEq(vault.owed(borrower, address(wnat)), MARGIN); // margin released
    }

    function test_repay_overpaymentBecomesChangeNotUnderflow() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR + 5_000 ether);
        assertEq(vault.getLoan(id).outstanding, 0);
        assertEq(vault.owed(lender, address(wnat)), DEBT_FLR);
        assertEq(vault.owed(borrower, address(wnat)), 5_000 ether + MARGIN);
    }

    function test_repay_afterRepaidReverts() public {
        uint256 id = _openAndDraw();
        vm.startPrank(borrower);
        vault.repay(id, DEBT_FLR);
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.WrongStatus.selector, id, LoanVault.Status.Repaid, LoanVault.Status.Drawn)
        );
        vault.repay(id, 1 ether);
        vm.stopPrank();
    }

    // --- interest: the floating pass-rate, accrued per posted epoch ---

    function test_interest_accruesAtPassRate() public {
        uint256 id = _openAndDraw();
        _postAlive(); // one epoch passes, 3 passes held -> benchmark + 1pt = 600bps
        vault.accrue(id);
        uint256 expected = DEBT_FLR + TermsLib.epochInterest(DEBT_FLR, 600, 1, EPOCH_SECONDS);
        assertEq(vault.getLoan(id).outstanding, expected);
        assertGt(expected, DEBT_FLR); // interest is real
    }

    function test_interest_strikeRaisesTheRate() public {
        uint256 id = _openAndDraw();
        oracle.post(borrower, ++epoch, TRAILING, 0, 20, true); // record broke: 0 passes
        vault.accrue(id);
        // 0 passes -> benchmark + 4pts = 900bps
        assertEq(vault.getLoan(id).outstanding, DEBT_FLR + TermsLib.epochInterest(DEBT_FLR, 900, 1, EPOCH_SECONDS));
    }

    function test_interest_accrualIsIdempotentPerEpoch() public {
        uint256 id = _openAndDraw();
        _postAlive();
        vault.accrue(id);
        uint256 after1 = vault.getLoan(id).outstanding;
        vault.accrue(id); // same epoch again: no double-charge
        assertEq(vault.getLoan(id).outstanding, after1);
    }

    // --- default machinery: state trigger, cure, settlement ---

    function test_trip_beforeFourDeadEpochsReverts() public {
        uint256 id = _openAndDraw();
        _postDead();
        _postDead();
        _postDead();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.TriggerNotMet.selector, id));
        vault.trip(id);
    }

    function test_deadStreakResetsOnAliveEpoch() public {
        // long term so this exercises dead-streak logic, not maturity default
        uint256 id = _openAndDrawTerm(100);
        _postDead();
        _postDead();
        _postDead();
        _postAlive(); // recovery: a zero-reward stretch alone never defaults anyone
        _postDead();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.TriggerNotMet.selector, id));
        vault.trip(id);
    }

    // --- HIGH-1: maturity is a settleable default even for a live validator ---

    function test_maturity_liveButUnpaidBorrowerCanBeTripped() public {
        uint256 id = _openAndDrawTerm(4); // matures 4 epochs after draw
        // validator stays perfectly alive but never repays
        for (uint256 i; i < 4; i++) _postAlive();
        // before maturity: not trippable
        // (draw epoch was 101; matures 105; we're now at 105)
        vault.trip(id); // at/after maturity with outstanding>0 -> Grace
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Grace));
    }

    function test_maturity_notTrippableBeforeTerm() public {
        uint256 id = _openAndDrawTerm(10);
        for (uint256 i; i < 3; i++) _postAlive(); // alive, well before maturity
        vm.expectRevert(abi.encodeWithSelector(LoanVault.TriggerNotMet.selector, id));
        vault.trip(id);
    }

    function test_maturity_fullyRepaidNeverTrips() public {
        uint256 id = _openAndDrawTerm(4);
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR); // paid off before maturity
        for (uint256 i; i < 6; i++) _postAlive(); // sail past maturity
        // Repaid is terminal; trip requires Drawn
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.WrongStatus.selector, id, LoanVault.Status.Repaid, LoanVault.Status.Drawn)
        );
        vault.trip(id);
    }

    function test_trip_afterFourDeadEpochsStartsGrace() public {
        uint256 id = _openAndDraw();
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id); // anyone may call
        LoanVault.Loan memory loan = vault.getLoan(id);
        assertEq(uint8(loan.status), uint8(LoanVault.Status.Grace));
        assertEq(loan.graceEndsAt, uint64(block.timestamp) + 7 days);
    }

    // HIGH-2: a dust payment during Grace does NOT reset the loan to Drawn,
    // so it can no longer be used to stall settlement forever.
    function test_grace_dustDoesNotCure() public {
        uint256 id = _openAndDrawTerm(100); // long term: isolate dead-stream default
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        // a griefer (not even a party) pays 1 wei
        wnat.mint(stranger, 1);
        vm.startPrank(stranger);
        wnat.approve(address(vault), type(uint256).max);
        vault.repay(id, 1); // 1 wei
        vm.stopPrank();
        // still in Grace — the settlement clock keeps running
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Grace));
        vm.warp(block.timestamp + 7 days);
        vault.settle(id); // settlement proceeds despite the dust
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Settled));
    }

    // A borrower CAN still save the loan during Grace — by fully repaying.
    function test_grace_fullRepaymentHeals() public {
        uint256 id = _openAndDrawTerm(100);
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        uint256 owed = vault.getLoan(id).outstanding;
        vm.prank(borrower);
        vault.repay(id, owed);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        assertEq(vault.owed(borrower, address(wnat)), MARGIN); // margin released
    }

    function test_settle_beforeGraceEndsReverts() public {
        uint256 id = _openAndDraw();
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.GraceNotExpired.selector, id, uint64(block.timestamp) + 7 days)
        );
        vault.settle(id);
    }

    function test_settle_takesExactlyDebtPlusFee_restToBorrower() public {
        uint256 id = _openAndDraw();
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        uint256 outstanding = vault.getLoan(id).outstanding; // accrued through trip
        vm.warp(block.timestamp + 7 days);
        vault.settle(id);

        uint256 due = outstanding + DEFAULT_FEE;
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Settled));
        assertEq(vault.owed(lender, address(wnat)), due); // recovery, exactly
        assertEq(vault.owed(borrower, address(wnat)), MARGIN - due); // never a jackpot
    }

    function test_settle_shortfallCapsAtMargin() public {
        // consented default fee larger than the margin cushion forces shortfall
        vm.prank(lender);
        uint256 id =
            vault.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, 60_000 ether, BENCHMARK_BPS, TERM_EPOCHS);
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();

        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        vm.warp(block.timestamp + 7 days);
        vault.settle(id);

        assertEq(vault.owed(lender, address(wnat)), MARGIN); // capped at margin
        assertEq(vault.owed(borrower, address(wnat)), 0);
    }

    // --- M-09: inexact-delivery tokens are rejected, not mis-accounted ---

    function test_feeOnTransferPrincipalIsRejected() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        LoanVault.Config memory cfg = _config(0);
        cfg.usd = IERC20(address(feeToken));
        LoanVault feeVault = new LoanVault(cfg);
        feeToken.mint(lender, PRINCIPAL_USD);
        vm.startPrank(lender);
        feeToken.approve(address(feeVault), type(uint256).max);
        uint256 id =
            feeVault.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.stopPrank();
        vm.prank(borrower);
        feeVault.accept(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanVault.InexactTransfer.selector, PRINCIPAL_USD, PRINCIPAL_USD - PRINCIPAL_USD / 100
            )
        );
        vm.prank(lender);
        feeVault.fund(id);
    }

    // --- escrow hardening ---

    function test_escrow_releaseByNonVaultReverts() public {
        uint256 id = _offer();
        vm.startPrank(borrower);
        vault.accept(id);
        vault.postMargin(id);
        vm.stopPrank();
        MarginEscrow escrow = vault.getLoan(id).escrow;
        vm.expectRevert(MarginEscrow.NotVault.selector);
        vm.prank(borrower);
        escrow.releaseToVault(1 ether);
    }
}

contract RewardCollectorTest is LoanVaultTestBase {
    uint256 id;
    RewardCollector collector;

    function setUp() public override {
        super.setUp();
        id = _openAndDraw();
        collector = vault.getLoan(id).collector;
    }

    function test_sweep_wrapsNativeAndRepays() public {
        // a reward manager claim delivers native FLR to the collector
        vm.deal(address(collector), 3_000 ether);
        vm.prank(stranger); // the keeper is anyone
        collector.sweep();
        assertEq(vault.getLoan(id).outstanding, DEBT_FLR - 3_000 ether);
        assertEq(vault.owed(lender, address(wnat)), 3_000 ether);
        assertEq(address(collector).balance, 0);
        assertEq(wnat.balanceOf(address(collector)), 0);
    }

    function test_sweep_afterRepaid_routesToBorrower() public {
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR); // loan done
        uint256 balBefore = wnat.balanceOf(borrower);
        vm.deal(address(collector), 1_000 ether); // stream keeps flowing
        collector.sweep();
        // the stream belongs to the borrower again — collector never keeps funds
        assertEq(wnat.balanceOf(borrower), balBefore + 1_000 ether);
    }

    function test_sweep_beforeDrawReverts() public {
        // fresh loan still Open: collector exists but must hold, not route
        uint256 id2 = _offer();
        vm.prank(borrower);
        vault.accept(id2);
        RewardCollector c2 = vault.getLoan(id2).collector;
        vm.deal(address(c2), 100 ether);
        vm.expectRevert(RewardCollector.LoanNotActiveYet.selector);
        c2.sweep();
    }

    function test_sweep_emptyReverts() public {
        vm.expectRevert(RewardCollector.NothingToSweep.selector);
        collector.sweep();
    }

    function test_sweep_overpaymentStillSafe() public {
        // final epoch's claim exceeds what's left: excess must become change
        vm.deal(address(collector), DEBT_FLR + 7_000 ether);
        collector.sweep();
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        assertEq(vault.owed(lender, address(wnat)), DEBT_FLR);
        assertEq(vault.owed(borrower, address(wnat)), 7_000 ether + MARGIN);
    }
}

contract PassLedgerOracleTest is Test {
    PassLedgerOracle oracle;
    address keeper = makeAddr("keeper");
    address validator = makeAddr("validator");

    function setUp() public {
        oracle = new PassLedgerOracle(address(this), IFlareContractRegistry(address(0)), 8);
    }

    function test_post_byNonPosterReverts() public {
        vm.expectRevert(PassLedgerOracle.NotPoster.selector);
        vm.prank(keeper);
        oracle.post(validator, 1, 1 ether, 3, 20, true);
    }

    function test_post_epochsMustStrictlyIncrease() public {
        oracle.post(validator, 5, 1 ether, 3, 20, true);
        vm.expectRevert(abi.encodeWithSelector(PassLedgerOracle.EpochNotAfterLast.selector, 5, 5));
        oracle.post(validator, 5, 1 ether, 3, 20, true);
        vm.expectRevert(abi.encodeWithSelector(PassLedgerOracle.EpochNotAfterLast.selector, 4, 5));
        oracle.post(validator, 4, 1 ether, 3, 20, true);
    }

    function test_deadStreak_countsAndResets() public {
        oracle.post(validator, 1, 1 ether, 3, 20, false);
        oracle.post(validator, 2, 1 ether, 3, 20, false);
        assertEq(oracle.latest(validator).deadStreak, 2);
        oracle.post(validator, 3, 1 ether, 3, 20, true);
        assertEq(oracle.latest(validator).deadStreak, 0);
    }

    function test_setPoster_handsOverAndLocksOut() public {
        oracle.setPoster(keeper);
        vm.expectRevert(PassLedgerOracle.NotPoster.selector);
        oracle.post(validator, 1, 1 ether, 3, 20, true); // old poster locked out
        vm.prank(keeper);
        oracle.post(validator, 1, 1 ether, 3, 20, true);
        assertEq(oracle.latest(validator).epochId, 1);
    }

    // --- G12: backup posters (keeper redundancy) ---

    function test_backupPoster_canPostAlongsidePrimary() public {
        oracle.setBackupPoster(keeper, true);
        vm.prank(keeper);
        oracle.post(validator, 1, 1 ether, 3, 20, true);
        oracle.post(validator, 2, 1 ether, 3, 20, true); // primary still works too
        assertEq(oracle.latest(validator).epochId, 2);
    }

    function test_backupPoster_onlyAdminGrants() public {
        vm.expectRevert(PassLedgerOracle.NotPoster.selector);
        vm.prank(keeper);
        oracle.setBackupPoster(keeper, true);
    }

    function test_backupPoster_revocable() public {
        oracle.setBackupPoster(keeper, true);
        oracle.setBackupPoster(keeper, false);
        vm.expectRevert(PassLedgerOracle.NotPoster.selector);
        vm.prank(keeper);
        oracle.post(validator, 1, 1 ether, 3, 20, true);
    }
}
