// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice The slice of Flare's PChainStakeMirror that Tributary reads.
///         Mirrors live P-chain stakes on the C-chain: for an owner, the node
///         ids they stake to and the amounts. A P-chain stake cannot exit
///         early, and the mirror drops it when it ends — so "the mirror still
///         shows the stake" is a live, trustless commitment check.
///         (stakesOf verified against the real Coston2 contract, 2026-08-28.)
interface IPChainStakeMirror {
    function stakesOf(address owner)
        external
        view
        returns (bytes20[] memory nodeIds, uint256[] memory amounts);
}
