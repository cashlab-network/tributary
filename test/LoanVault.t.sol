// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoanVault} from "../src/LoanVault.sol";

contract LoanVaultTest is Test {
    LoanVault vault;
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vault = new LoanVault();
    }

    function _offer() internal returns (uint256 id) {
        vm.prank(lender);
        id = vault.offer(borrower, 100 ether, 500, 4);
    }

    // --- the H-04 failing case: bogus ids must revert everywhere ---

    function test_accept_bogusIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 999));
        vm.prank(borrower);
        vault.accept(999);
    }

    function test_cancel_bogusIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 0));
        vm.prank(lender);
        vault.cancelOffer(0); // id 0 is never valid
    }

    function test_getLoan_bogusIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(LoanVault.LoanDoesNotExist.selector, 7));
        vault.getLoan(7);
    }

    // --- consent is party-scoped and value-free ---

    function test_offer_thenAccept_opensLoan() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Open));
    }

    function test_accept_byNonBorrowerReverts() public {
        uint256 id = _offer();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotParty.selector, id, stranger));
        vm.prank(stranger);
        vault.accept(id);
    }

    function test_accept_byLenderReverts() public {
        // the lender consenting on the borrower's behalf is an attack, not a convenience
        uint256 id = _offer();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.NotParty.selector, id, lender));
        vm.prank(lender);
        vault.accept(id);
    }

    // --- M-02: offers are revocable until consumed, then never again ---

    function test_cancelOffer_byLenderCloses() public {
        uint256 id = _offer();
        vm.prank(lender);
        vault.cancelOffer(id);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Closed));
    }

    function test_cancelOffer_afterAcceptReverts() public {
        // a consumed consent cannot be re-litigated by cancellation
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

    function test_accept_twiceReverts() public {
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                LoanVault.WrongStatus.selector, id, LoanVault.Status.Open, LoanVault.Status.Offered
            )
        );
        vm.prank(borrower);
        vault.accept(id);
    }

    // --- input hygiene ---

    function test_offer_zeroBorrowerReverts() public {
        vm.expectRevert(LoanVault.ZeroAddress.selector);
        vm.prank(lender);
        vault.offer(address(0), 100 ether, 500, 4);
    }

    function test_offer_zeroPrincipalReverts() public {
        vm.expectRevert(LoanVault.ZeroAmount.selector);
        vm.prank(lender);
        vault.offer(borrower, 0, 500, 4);
    }
}
