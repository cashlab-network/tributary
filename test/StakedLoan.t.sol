// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {LoanVault} from "../src/LoanVault.sol";
import {LoanVaultTestBase} from "./LoanVault.t.sol";

/// Tier A — STAKED loans. The borrower has a live P-chain stake (via the
/// mirror) that must outlive the debt. If the mirror shows it gone or short
/// while anything is owed, that is a settleable default — checkable by anyone.
contract StakedLoanTest is LoanVaultTestBase {
    bytes20 constant NODE = bytes20(hex"1111111111111111111111111111111111111111");
    uint256 constant MIN_STAKE = 1_000_000 ether;

    function _offerStaked() internal returns (uint256 id) {
        vm.prank(lender);
        id = vault.offerStaked(
            borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS, NODE, MIN_STAKE
        );
    }

    function test_accept_requiresLiveStake() public {
        uint256 id = _offerStaked();
        // no stake in the mirror -> accept reverts
        vm.expectRevert(abi.encodeWithSelector(LoanVault.StakeCommitmentBroken.selector, MIN_STAKE, 0));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_accept_shortStakeReverts() public {
        mirror.setStake(borrower, NODE, MIN_STAKE - 1);
        uint256 id = _offerStaked();
        vm.expectRevert(abi.encodeWithSelector(LoanVault.StakeCommitmentBroken.selector, MIN_STAKE, MIN_STAKE - 1));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_stakedLoan_fullCycle() public {
        mirror.setStake(borrower, NODE, MIN_STAKE);
        uint256 id = _offerStaked();
        vm.prank(borrower);
        vault.accept(id);
        assertEq(vault.getLoan(id).stakeNodeId, NODE);
        assertEq(vault.getLoan(id).minStake, MIN_STAKE);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vault.repay(id, DEBT_FLR);
        vm.stopPrank();
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
    }

    // THE COMMITMENT RULE: pull your stake while owing -> trippable -> settle.
    function test_stakePulledWhileOwing_isDefault() public {
        mirror.setStake(borrower, NODE, MIN_STAKE);
        uint256 id = _offerStaked();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();

        // before pulling: not trippable (stake live, not dead, not matured)
        vm.expectRevert(abi.encodeWithSelector(LoanVault.TriggerNotMet.selector, id));
        vault.trip(id);

        // borrower's P-chain stake ends -> mirror drops it
        mirror.clearStakes(borrower);
        // now ANYONE can trip -> grace -> settle
        vault.trip(id);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Grace));
        vm.warp(block.timestamp + 7 days);
        vault.settle(id);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Settled));
    }

    function test_stakePulledAfterRepaid_cannotTrip() public {
        mirror.setStake(borrower, NODE, MIN_STAKE);
        uint256 id = _offerStaked();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vault.repay(id, DEBT_FLR); // paid off
        vm.stopPrank();
        mirror.clearStakes(borrower); // stake ends AFTER payoff — fine
        vm.expectRevert(
            abi.encodeWithSelector(LoanVault.WrongStatus.selector, id, LoanVault.Status.Repaid, LoanVault.Status.Drawn)
        );
        vault.trip(id);
    }
}
