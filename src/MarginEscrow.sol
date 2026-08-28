// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWNat} from "./interfaces/IWNat.sol";

interface IClaimSetup {
    function setClaimExecutors(address[] calldata executors) external payable;
    function setAllowedClaimRecipients(address[] calldata recipients) external;
}

/// @title MarginEscrow — per-loan WFLR margin holder
/// @notice One instance per loan, deployed by the LoanVault. Holds exactly one
///         loan's margin and vote-power-delegates 100% of its own balance.
///         WNat percentage delegation is account-wide, which is the reason
///         escrows are per-loan instances rather than one shared pot.
///
///         TWO MODES, set by who the delegatee/recipient are:
///         - VALIDATOR mode: delegatee = the borrower (their network weight
///           doesn't drop while pledged), claim recipient = the borrower (the
///           collateral's own FSP earnings stay theirs).
///         - SELF-CONTAINED DELEGATOR mode: delegatee = an FTSO provider and
///           claim recipient = the loan's RewardCollector — the locked
///           collateral itself generates the yield that repays the loan, and
///           the borrower cannot switch that stream off, because the escrow
///           holds the stake.
///
///         Either way the escrow enrolls its claims at birth (keeper may
///         execute; exactly one allowed recipient) so the delegation's
///         rewards never expire unclaimable.
///
///         Funds leave only to the vault, which routes them onward via
///         pull-withdrawals (M-11).
contract MarginEscrow {
    error NotVault();

    IWNat public immutable wnat;
    address public immutable vault;
    address public immutable delegatee; // where the escrow's vote power points
    address public immutable claimRecipient; // where its FSP earnings may land

    constructor(
        IWNat wnat_,
        address delegatee_,
        address claimSetupManager,
        address keeperExecutor,
        address claimRecipient_
    ) {
        wnat = wnat_;
        vault = msg.sender;
        delegatee = delegatee_;
        claimRecipient = claimRecipient_;
        // Applies to the whole (future) balance of this escrow account.
        wnat_.delegate(delegatee_, 10_000);
        if (claimSetupManager != address(0)) {
            address[] memory execs = new address[](1);
            execs[0] = keeperExecutor;
            address[] memory recips = new address[](1);
            recips[0] = claimRecipient_;
            IClaimSetup(claimSetupManager).setClaimExecutors(execs);
            IClaimSetup(claimSetupManager).setAllowedClaimRecipients(recips);
        }
    }

    /// @notice Release margin back to the vault, which credits the rightful
    ///         party's withdrawable balance. Never pays end users directly.
    function releaseToVault(uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        wnat.transfer(vault, amount);
    }

    function balance() external view returns (uint256) {
        return wnat.balanceOf(address(this));
    }
}
