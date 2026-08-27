// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {MarginEscrow} from "../src/MarginEscrow.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {MockERC20, MockWNat, FeeOnTransferToken} from "./mocks/Tokens.sol";

contract LoanVaultTest is Test {
    LoanVault vault;
    MockERC20 usd;
    MockWNat wnat;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address stranger = makeAddr("stranger");

    uint256 constant PRINCIPAL_USD = 1_000e6; // 1,000 USDT0
    uint256 constant DEBT_FLR = 50_000 ether; // locked forward price
    uint256 constant MARGIN = 100_000 ether; // 2x debt in WFLR

    function setUp() public {
        usd = new MockERC20("USDT0");
        wnat = new MockWNat();
        vault = new LoanVault(IERC20(address(usd)), IWNat(address(wnat)));

        usd.mint(lender, PRINCIPAL_USD);
        wnat.mint(borrower, MARGIN + DEBT_FLR);
        vm.prank(lender);
        usd.approve(address(vault), type(uint256).max);
        vm.startPrank(borrower);
        wnat.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _offer() internal returns (uint256 id) {
        vm.prank(lender);
        id = vault.offer(borrower, PRINCIPAL_USD, DEBT_FLR, MARGIN, 500, 4);
    }

    function _openAndDraw() internal returns (uint256 id) {
        id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();
    }

    // --- the H-04 failing case: bogus ids must revert everywhere ---

    function test_accept_bogusIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 999));
        vm.prank(borrower);
        vault.accept(999);
    }

    function test_lifecycle_bogusIdRevertsEverywhere() public {
        bytes memory err = abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 0);
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
        vault.getLoan(0);
    }

    // --- consent: party-scoped, value-free, revocable-until-consumed ---

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
            abi.encodeWithSelector(
                LoanVault.WrongStatus.selector, id, LoanVault.Status.Open, LoanVault.Status.Offered
            )
        );
        vm.prank(lender);
        vault.cancelOffer(id);
    }

    function test_offer_zeroValuesRevert() public {
        vm.startPrank(lender);
        vm.expectRevert(LoanVault.ZeroAddress.selector);
        vault.offer(address(0), 1, 1, 1, 500, 4);
        vm.expectRevert(LoanVault.ZeroAmount.selector);
        vault.offer(borrower, 0, 1, 1, 500, 4);
        vm.expectRevert(LoanVault.ZeroAmount.selector);
        vault.offer(borrower, 1, 0, 1, 500, 4);
        vm.expectRevert(LoanVault.ZeroAmount.selector);
        vault.offer(borrower, 1, 1, 0, 500, 4);
        vm.stopPrank();
    }

    // --- funding + margin + draw gating ---

    function test_fund_byNonLenderReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotParty.selector, id, stranger));
        vm.prank(stranger);
        vault.fund(id);
    }

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

    function test_draw_withoutFundingReverts() public {
        uint256 id = _offer();
        vm.startPrank(borrower);
        vault.accept(id);
        vault.postMargin(id);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotReadyToDraw.selector, id, false, true));
        vault.draw(id);
        vm.stopPrank();
    }

    function test_draw_withoutMarginReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotReadyToDraw.selector, id, true, false));
        vm.prank(borrower);
        vault.draw(id);
    }

    function test_draw_paysBorrowerExactly() public {
        _openAndDraw();
        assertEq(usd.balanceOf(borrower), PRINCIPAL_USD);
        assertEq(usd.balanceOf(address(vault)), 0);
    }

    function test_postMargin_escrowDelegatesBackToBorrower() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(borrower);
        vault.postMargin(id);
        address escrow = address(vault.getLoan(id).escrow);
        // collateral that keeps working: escrow's whole balance delegated back
        assertEq(wnat.balanceOf(escrow), MARGIN);
        assertEq(wnat.delegatee(escrow), borrower);
        assertEq(wnat.delegatedBips(escrow), 10_000);
    }

    // --- cancelOpen: both refunds via pull, neither party can block the other ---

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

        vm.prank(lender);
        vault.withdraw(address(usd));
        vm.prank(borrower);
        vault.withdraw(address(wnat));
        assertEq(usd.balanceOf(lender), PRINCIPAL_USD);
        assertEq(wnat.balanceOf(borrower), MARGIN + DEBT_FLR);
    }

    function test_cancelOpen_afterDrawReverts() public {
        uint256 id = _openAndDraw();
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanVault.WrongStatus.selector, id, LoanVault.Status.Drawn, LoanVault.Status.Open
            )
        );
        vm.prank(lender);
        vault.cancelOpen(id);
    }

    // --- repayment: capped application, excess as change, margin release ---

    function test_repay_partialThenFull() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, 20_000 ether);
        assertEq(vault.getLoan(id).outstandingFlr, 30_000 ether);
        assertEq(vault.owed(lender, address(wnat)), 20_000 ether);

        vm.prank(borrower);
        vault.repay(id, 30_000 ether);
        assertEq(vault.getLoan(id).outstandingFlr, 0);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        // margin auto-released to borrower's pull balance
        assertEq(vault.owed(borrower, address(wnat)), MARGIN);

        vm.prank(lender);
        vault.withdraw(address(wnat));
        assertEq(wnat.balanceOf(lender), DEBT_FLR);
    }

    function test_repay_overpaymentBecomesChangeNotUnderflow() public {
        // the Debt DAO H-06 failing case at the vault level
        uint256 id = _openAndDraw();
        wnat.mint(borrower, 5_000 ether); // cover the deliberate overpayment
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR + 5_000 ether);
        assertEq(vault.getLoan(id).outstandingFlr, 0);
        assertEq(vault.owed(lender, address(wnat)), DEBT_FLR);
        // change + released margin both credited to borrower
        assertEq(vault.owed(borrower, address(wnat)), 5_000 ether + MARGIN);
    }

    function test_repay_byStrangerIsAllowedAndHarmless() public {
        // the RewardCollector will be "a stranger" to the loan parties
        uint256 id = _openAndDraw();
        wnat.mint(stranger, 1_000 ether);
        vm.startPrank(stranger);
        wnat.approve(address(vault), type(uint256).max);
        vault.repay(id, 1_000 ether);
        vm.stopPrank();
        assertEq(vault.getLoan(id).outstandingFlr, DEBT_FLR - 1_000 ether);
        assertEq(vault.owed(lender, address(wnat)), 1_000 ether);
    }

    function test_repay_beforeDrawReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanVault.WrongStatus.selector, id, LoanVault.Status.Open, LoanVault.Status.Drawn
            )
        );
        vm.prank(borrower);
        vault.repay(id, 1 ether);
    }

    function test_repay_afterRepaidReverts() public {
        // no state may resurrect a settled debt
        uint256 id = _openAndDraw();
        vm.startPrank(borrower);
        vault.repay(id, DEBT_FLR);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanVault.WrongStatus.selector, id, LoanVault.Status.Repaid, LoanVault.Status.Drawn
            )
        );
        vault.repay(id, 1 ether);
        vm.stopPrank();
    }

    // --- withdrawals ---

    function test_withdraw_zeroesBeforeTransfer_andEmptyReverts() public {
        uint256 id = _openAndDraw();
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR);
        vm.startPrank(lender);
        vault.withdraw(address(wnat));
        vm.expectRevert(LoanVault.NothingToWithdraw.selector);
        vault.withdraw(address(wnat));
        vm.stopPrank();
    }

    // --- M-09: inexact-delivery tokens are rejected, not mis-accounted ---

    function test_feeOnTransferPrincipalIsRejected() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        LoanVault feeVault = new LoanVault(IERC20(address(feeToken)), IWNat(address(wnat)));
        feeToken.mint(lender, PRINCIPAL_USD);
        vm.startPrank(lender);
        feeToken.approve(address(feeVault), type(uint256).max);
        uint256 id = feeVault.offer(borrower, PRINCIPAL_USD, DEBT_FLR, MARGIN, 500, 4);
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
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(borrower);
        vault.postMargin(id);
        MarginEscrow escrow = vault.getLoan(id).escrow;
        vm.expectRevert(MarginEscrow.NotVault.selector);
        vm.prank(borrower);
        escrow.releaseToVault(1 ether);
    }

    // --- conservation: no path mints or loses value ---

    function testFuzz_repay_conservation(uint96 payment) public {
        vm.assume(payment > 0);
        uint256 id = _openAndDraw();
        wnat.mint(borrower, payment); // ensure balance regardless of fuzz size
        vm.prank(borrower);
        vault.repay(id, payment);
        uint256 applied = payment >= DEBT_FLR ? DEBT_FLR : payment;
        assertEq(vault.getLoan(id).outstandingFlr, DEBT_FLR - applied);
        // everything paid in is credited out to someone; vault keeps nothing
        uint256 credits = vault.owed(lender, address(wnat)) + vault.owed(borrower, address(wnat));
        uint256 escrowStillHolds = vault.getLoan(id).outstandingFlr == 0 ? 0 : MARGIN;
        assertEq(credits + escrowStillHolds, uint256(payment) + MARGIN);
    }
}
