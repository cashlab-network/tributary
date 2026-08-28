// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {LoanVault} from "../src/LoanVault.sol";
import {MarginEscrow} from "../src/MarginEscrow.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {LoanVaultTestBase} from "./LoanVault.t.sol";

/// The everyday-holder product: a self-contained delegator loan. The margin
/// escrow delegates to an FTSO provider (not the borrower) and routes its own
/// FSP earnings to the loan's collector — so the locked collateral generates
/// the repayment stream and the borrower cannot switch it off.
contract DelegatorLoanTest is LoanVaultTestBase {
    address provider = makeAddr("ftsoProvider");

    function test_streamMode_escrowDelegatesToProvider_earningsToCollector() public {
        vm.prank(lender);
        uint256 id = vault.offerStream(
            borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS, provider
        );
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(borrower);
        vault.postMargin(id);

        address escrow = address(vault.getLoan(id).escrow);
        address collector = address(vault.getLoan(id).collector);

        // collateral's vote power points at the PROVIDER, not the borrower
        assertEq(wnat.delegatee(escrow), provider);
        // its FSP earnings are enrolled to land on the loan's COLLECTOR
        assertEq(csm.recipientOf(escrow), collector);
        assertEq(csm.executorOf(escrow), keeper);
        // and the loan records the provider
        assertEq(vault.getLoan(id).streamProvider, provider);
    }

    function test_validatorMode_unchanged_delegatesToBorrower() public {
        // the plain offer() still delegates to the borrower + keeps earnings
        uint256 id = _offer();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(borrower);
        vault.postMargin(id);
        address escrow = address(vault.getLoan(id).escrow);
        assertEq(wnat.delegatee(escrow), borrower);
        assertEq(csm.recipientOf(escrow), borrower);
        assertEq(vault.getLoan(id).streamProvider, address(0));
    }

    function test_offerStream_zeroProviderReverts() public {
        vm.expectRevert(LoanVault.ZeroAddress.selector);
        vm.prank(lender);
        vault.offerStream(
            borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS, address(0)
        );
    }

    // a delegator loan still repays and settles like any other — the stream
    // wiring changes WHERE rewards come from, not the loan machinery
    function test_streamMode_repaysNormally() public {
        vm.prank(lender);
        uint256 id = vault.offerStream(
            borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS, provider
        );
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vault.repay(id, DEBT_FLR);
        vm.stopPrank();
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        assertEq(vault.owed(borrower, address(wnat)), MARGIN); // margin released
    }
}
