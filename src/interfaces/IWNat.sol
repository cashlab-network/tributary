// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "./IERC20.sol";

/// @notice The slice of Flare's WNat (wrapped native FLR) that Tributary uses.
///         Percentage delegation is account-wide: `bips` of the holder's whole
///         balance, applying dynamically to future balance changes.
interface IWNat is IERC20 {
    function delegate(address to, uint256 bips) external;
    function deposit() external payable;
}
