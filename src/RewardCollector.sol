// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IWNat} from "./interfaces/IWNat.sol";

interface ILoanVaultForCollector {
    function repay(uint256 id, uint256 amount) external;
    function statusOf(uint256 id) external view returns (uint8);
    function borrowerOf(uint256 id) external view returns (address);
}

/// @title RewardCollector — one per loan; the loan's registered claim target
/// @notice The borrower points their reward claims (ClaimSetupManager +
///         ValidatorRewardManager executor/recipient settings) at this
///         address. A keeper calls sweep() each epoch. Funds only ever move
///         to the vault as repayment on THIS loan, or to the borrower once
///         the loan is no longer active — never anywhere else, and never by
///         inference from an unregistered input (H-02).
contract RewardCollector {
    // Mirrors LoanVault.Status — collector only needs these distinctions.
    uint8 internal constant STATUS_DRAWN = 3;
    uint8 internal constant STATUS_GRACE = 4;

    error LoanNotActiveYet();
    error NothingToSweep();

    event Swept(uint256 indexed loanId, uint256 amount, bool toBorrower);

    IWNat public immutable wnat;
    ILoanVaultForCollector public immutable vault;
    uint256 public immutable loanId;

    constructor(IWNat wnat_, uint256 loanId_) {
        wnat = wnat_;
        vault = ILoanVaultForCollector(msg.sender);
        loanId = loanId_;
        wnat_.approve(msg.sender, type(uint256).max);
    }

    /// @notice Native FLR arrives here from reward manager claims.
    receive() external payable {}

    /// @notice Wrap any native balance and route the full WNat balance:
    ///         to the vault as repayment while the loan is Drawn/Grace,
    ///         to the borrower once the loan is terminal (their rewards
    ///         again), and never before the loan is active.
    function sweep() external {
        if (address(this).balance != 0) {
            wnat.deposit{value: address(this).balance}();
        }
        uint256 bal = wnat.balanceOf(address(this));
        if (bal == 0) revert NothingToSweep();

        uint8 status = vault.statusOf(loanId);
        if (status == STATUS_DRAWN || status == STATUS_GRACE) {
            vault.repay(loanId, bal);
            emit Swept(loanId, bal, false);
        } else if (status > STATUS_GRACE) {
            // Settled / Repaid / Closed: the stream belongs to the borrower again.
            wnat.transfer(vault.borrowerOf(loanId), bal);
            emit Swept(loanId, bal, true);
        } else {
            revert LoanNotActiveYet();
        }
    }
}
