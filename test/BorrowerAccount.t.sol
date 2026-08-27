// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BorrowerAccount} from "../src/BorrowerAccount.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {MockERC20} from "./mocks/Tokens.sol";
import {LoanVaultTestBase} from "./LoanVault.t.sol";

contract BorrowerAccountTest is LoanVaultTestBase {
    BorrowerAccount account;
    uint256 id;
    RewardCollector collector;
    MockERC20 rewardToken;

    function setUp() public override {
        super.setUp();
        vm.prank(borrower);
        account = new BorrowerAccount(borrower);
        id = _openAndDraw();
        collector = vault.getLoan(id).collector;
        rewardToken = new MockERC20("SomeReward");
    }

    function _bind(address[] memory allowed) internal {
        vm.prank(borrower);
        account.bind(address(vault), id, address(collector), allowed);
    }

    // --- binding rules ---

    function test_bind_onlyOwner() public {
        vm.expectRevert(BorrowerAccount.NotOwner.selector);
        vm.prank(stranger);
        account.bind(address(vault), id, address(collector), new address[](0));
    }

    function test_bind_rejectsForeignLoan() public {
        // a loan whose borrower is neither this account nor its owner
        vm.prank(lender);
        uint256 foreignId =
            vault.offer(stranger, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(BorrowerAccount.NotThisAccountsLoan.selector);
        vm.prank(borrower);
        account.bind(address(vault), foreignId, address(collector), new address[](0));
    }

    function test_bind_twiceReverts() public {
        _bind(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(BorrowerAccount.AlreadyBound.selector, id));
        vm.prank(borrower);
        account.bind(address(vault), id, address(collector), new address[](0));
    }

    // --- the fence: while bound, the owner cannot move value out ---

    function test_bound_ownerCannotTransferTokensOut() public {
        _bind(new address[](0));
        rewardToken.mint(address(account), 100 ether);
        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.exec(address(rewardToken), 0, abi.encodeCall(MockERC20.transfer, (borrower, 100 ether)));
    }

    function test_bound_ownerCannotApproveDrains() public {
        _bind(new address[](0));
        rewardToken.mint(address(account), 100 ether);
        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.exec(address(rewardToken), 0, abi.encodeCall(MockERC20.approve, (borrower, type(uint256).max)));
    }

    function test_bound_ownerCannotSendValue() public {
        _bind(new address[](0));
        vm.deal(address(account), 10 ether);
        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.exec(borrower, 1 ether, "");
    }

    function test_bound_sweepToOwnerReverts() public {
        _bind(new address[](0));
        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.sweepToOwner(address(rewardToken));
    }

    function test_bound_allowlistedTargetStillWorks() public {
        // e.g. a governance/claim contract the lender agreed to at bind time
        MockERC20 unrelated = new MockERC20("Gov");
        address[] memory allowed = new address[](1);
        allowed[0] = address(unrelated);
        _bind(allowed);
        vm.prank(borrower);
        account.exec(address(unrelated), 0, abi.encodeCall(MockERC20.approve, (borrower, 1)));
        assertEq(unrelated.allowance(address(account), borrower), 1);
    }

    function test_bind_collectorNeverAllowlisted() public {
        address[] memory allowed = new address[](1);
        allowed[0] = address(collector); // sneaky: list the collector itself
        _bind(allowed);
        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.exec(address(collector), 0, abi.encodeCall(RewardCollector.sweep, ()));
    }

    // --- routing: rewards reaching the account flow to the loan ---

    function test_route_nativeAndTokensReachCollectorThenVault() public {
        _bind(new address[](0));
        vm.deal(address(account), 2_000 ether); // a claimed reward, native
        vm.prank(stranger); // keepers are anyone
        account.routeToCollector(address(0));
        assertEq(address(collector).balance, 2_000 ether);
        collector.sweep(); // wraps + repays
        assertEq(vault.getLoan(id).outstanding, DEBT_FLR - 2_000 ether);
    }

    function test_route_whileUnboundReverts() public {
        vm.expectRevert(BorrowerAccount.NotBound.selector);
        account.routeToCollector(address(0));
    }

    // --- self-expiry: the binding dies with the loan, trustlessly ---

    function test_release_whileLoanActiveReverts() public {
        _bind(new address[](0));
        vm.expectRevert(abi.encodeWithSelector(BorrowerAccount.LoanStillActive.selector, id));
        account.release();
    }

    function test_release_afterRepaid_restoresFullControl() public {
        _bind(new address[](0));
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR); // pay the loan off
        account.release(); // anyone may release now
        assertFalse(account.bound());

        // owner has their account back: value moves freely again
        rewardToken.mint(address(account), 50 ether);
        vm.prank(borrower);
        account.sweepToOwner(address(rewardToken));
        assertEq(rewardToken.balanceOf(borrower), 50 ether);
    }

    function test_release_thenRebind_usesFreshAllowlist() public {
        // allowlist from binding 1 must NOT leak into binding 2 (M-02 scope)
        MockERC20 gov = new MockERC20("Gov");
        address[] memory allowed = new address[](1);
        allowed[0] = address(gov);
        _bind(allowed);
        vm.prank(borrower);
        vault.repay(id, DEBT_FLR);
        account.release();

        // second loan, bound with an EMPTY allowlist
        _postAlive();
        vm.prank(lender);
        usd.mint(lender, PRINCIPAL_USD);
        vm.prank(lender);
        uint256 id2 = vault.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.prank(borrower);
        vault.accept(id2);
        address collector2 = address(vault.getLoan(id2).collector);
        vm.prank(borrower);
        account.bind(address(vault), id2, collector2, new address[](0));

        vm.expectRevert(BorrowerAccount.BindingForbidsThis.selector);
        vm.prank(borrower);
        account.exec(address(gov), 0, abi.encodeCall(MockERC20.approve, (borrower, 1)));
    }

    // --- unbound: the account is just the owner's wallet ---

    function test_unbound_fullControl() public {
        rewardToken.mint(address(account), 10 ether);
        vm.deal(address(account), 1 ether);
        vm.startPrank(borrower);
        account.exec(address(rewardToken), 0, abi.encodeCall(MockERC20.transfer, (borrower, 4 ether)));
        account.sweepToOwner(address(rewardToken));
        vm.stopPrank();
        assertEq(rewardToken.balanceOf(borrower), 10 ether);
        assertEq(borrower.balance, 1 ether);
    }
}
