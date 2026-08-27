// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWNat} from "./interfaces/IWNat.sol";

interface IClaimSetup {
    function setClaimExecutors(address[] calldata executors) external payable;
    function setAllowedClaimRecipients(address[] calldata recipients) external;
}

/// @title MarginEscrow — per-loan WFLR margin holder
/// @notice One instance per loan, deployed by the LoanVault. Holds exactly one
///         loan's margin and vote-power-delegates 100% of its own balance back
///         to the borrower — the published design's "collateral that keeps
///         working." WNat percentage delegation is account-wide, which is the
///         reason escrows are per-loan instances rather than one shared pot.
///
///         The delegation EARNS FSP rewards — and those accrue to the escrow
///         (the WNat holder), not the borrower. Without claim setup they
///         would sit unclaimable and expire (~90 days). So the escrow enrolls
///         itself at birth: the vault's keeper may execute claims, and the
///         BORROWER is the only allowed recipient — the collateral's earnings
///         flow to their owner, never to the vault or lender.
///
///         Funds leave only to the vault, which routes them onward via
///         pull-withdrawals (M-11).
contract MarginEscrow {
    error NotVault();

    IWNat public immutable wnat;
    address public immutable vault;
    address public immutable borrower;

    constructor(IWNat wnat_, address borrower_, address claimSetupManager, address keeperExecutor) {
        wnat = wnat_;
        vault = msg.sender;
        borrower = borrower_;
        // Applies to the whole (future) balance of this escrow account.
        wnat_.delegate(borrower_, 10_000);
        if (claimSetupManager != address(0)) {
            address[] memory execs = new address[](1);
            execs[0] = keeperExecutor;
            address[] memory recips = new address[](1);
            recips[0] = borrower_;
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
