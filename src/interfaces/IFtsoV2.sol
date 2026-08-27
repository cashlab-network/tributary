// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice The slice of Flare's FtsoV2 that Tributary uses. Block-latency
///         feeds are free to read (payable for the fee-bearing tiers).
interface IFtsoV2 {
    function getFeedById(bytes21 feedId)
        external
        payable
        returns (uint256 value, int8 decimals, uint64 timestamp);
}
