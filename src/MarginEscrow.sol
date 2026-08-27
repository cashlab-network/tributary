// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWNat} from "./interfaces/IWNat.sol";

/// @title MarginEscrow — per-loan WFLR margin holder
/// @notice One instance per loan, deployed by the LoanVault. Holds exactly one
///         loan's margin and vote-power-delegates 100% of its own balance back
///         to the borrower — the published design's "collateral that keeps
///         working." WNat percentage delegation is account-wide, which is the
///         reason escrows are per-loan instances rather than one shared pot.
///         Funds leave only to the vault, which routes them onward via
///         pull-withdrawals (M-11).
contract MarginEscrow {
    error NotVault();

    IWNat public immutable wnat;
    address public immutable vault;
    address public immutable borrower;

    constructor(IWNat wnat_, address borrower_) {
        wnat = wnat_;
        vault = msg.sender;
        borrower = borrower_;
        // Applies to the whole (future) balance of this escrow account.
        wnat_.delegate(borrower_, 10_000);
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
