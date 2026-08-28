// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {MockFSM, MockRegistry} from "./mocks/Tokens.sol";

/// The trustless lane (G1): postWithProof verifies a reward claim against the
/// root Flare's FlareSystemsManager signed. Tested with a synthetic 2-leaf
/// tree (the verification logic is identical to the mainnet path proven by
/// re-derivation in research/MERKLE-ORACLE-RESEARCH.md §1d).
contract MerkleOracleTest is Test {
    PassLedgerOracle oracle;
    MockFSM fsm;
    MockRegistry registry;

    bytes20 constant PROVIDER = bytes20(hex"00031123b50cdd187dc4d2982164b5458061b463");
    uint24 constant EPOCH = 426;

    function setUp() public {
        fsm = new MockFSM();
        registry = new MockRegistry(address(fsm));
        oracle = new PassLedgerOracle(address(this), IFlareContractRegistry(address(registry)), 1);
    }

    function _claim(uint120 amount, PassLedgerOracle.ClaimType t)
        internal
        pure
        returns (PassLedgerOracle.RewardClaim memory)
    {
        return PassLedgerOracle.RewardClaim({rewardEpochId: EPOCH, beneficiary: PROVIDER, amount: amount, claimType: t});
    }

    function _leaf(PassLedgerOracle.RewardClaim memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    function _sorted(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_validProof_provesFeeAndUpdatesTrailing() public {
        // 2-leaf tree: our FEE claim + a sibling
        PassLedgerOracle.RewardClaim memory feeClaim = _claim(33_449 ether, PassLedgerOracle.ClaimType.FEE);
        PassLedgerOracle.RewardClaim memory sibling = _claim(999 ether, PassLedgerOracle.ClaimType.WNAT);
        bytes32 leafA = _leaf(feeClaim);
        bytes32 leafB = _leaf(sibling);
        bytes32 root = _sorted(leafA, leafB);
        fsm.setRoot(EPOCH, root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        oracle.postWithProof(feeClaim, proof);

        (uint120 amt, bool proven) = oracle.provenRewards(PROVIDER, EPOCH, PassLedgerOracle.ClaimType.FEE);
        assertEq(amt, 33_449 ether);
        assertTrue(proven);
        assertEq(oracle.provenTrailingFee(PROVIDER), 33_449 ether);
    }

    function test_wrongProofReverts() public {
        PassLedgerOracle.RewardClaim memory feeClaim = _claim(33_449 ether, PassLedgerOracle.ClaimType.FEE);
        bytes32 root = _sorted(_leaf(feeClaim), keccak256("sibling"));
        fsm.setRoot(EPOCH, root);

        bytes32[] memory badProof = new bytes32[](1);
        badProof[0] = keccak256("not the sibling");
        vm.expectRevert(PassLedgerOracle.InvalidProof.selector);
        oracle.postWithProof(feeClaim, badProof);
    }

    function test_tamperedAmountReverts() public {
        // prove nothing changes if an attacker inflates the amount: the leaf
        // no longer matches, so the proof fails
        PassLedgerOracle.RewardClaim memory real = _claim(33_449 ether, PassLedgerOracle.ClaimType.FEE);
        bytes32 sib = keccak256("sib");
        fsm.setRoot(EPOCH, _sorted(_leaf(real), sib));

        PassLedgerOracle.RewardClaim memory inflated = _claim(999_999 ether, PassLedgerOracle.ClaimType.FEE);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;
        vm.expectRevert(PassLedgerOracle.InvalidProof.selector);
        oracle.postWithProof(inflated, proof);
    }

    function test_unsignedEpochReverts() public {
        PassLedgerOracle.RewardClaim memory c = _claim(1 ether, PassLedgerOracle.ClaimType.FEE);
        // no root set for EPOCH -> rewardsHash returns 0
        vm.expectRevert(abi.encodeWithSelector(PassLedgerOracle.RootNotSigned.selector, EPOCH));
        oracle.postWithProof(c, new bytes32[](0));
    }

    function test_doubleProveReverts() public {
        PassLedgerOracle.RewardClaim memory c = _claim(5 ether, PassLedgerOracle.ClaimType.FEE);
        bytes32 sib = keccak256("s");
        fsm.setRoot(EPOCH, _sorted(_leaf(c), sib));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;
        oracle.postWithProof(c, proof);
        vm.expectRevert(PassLedgerOracle.AlreadyProven.selector);
        oracle.postWithProof(c, proof);
    }

    function test_trailingAveragesMultipleFeeEpochs() public {
        // two epochs of proven FEE -> trailing = average
        _proveFee(426, 100 ether);
        _proveFee(427, 300 ether);
        assertEq(oracle.provenTrailingFee(PROVIDER), 200 ether); // (100+300)/2
    }

    function _proveFee(uint24 epochId, uint120 amount) internal {
        PassLedgerOracle.RewardClaim memory c =
            PassLedgerOracle.RewardClaim({rewardEpochId: epochId, beneficiary: PROVIDER, amount: amount, claimType: PassLedgerOracle.ClaimType.FEE});
        bytes32 sib = keccak256(abi.encode("sib", epochId));
        fsm.setRoot(epochId, _sorted(_leaf(c), sib));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;
        oracle.postWithProof(c, proof);
    }

    // single-leaf tree (empty proof): leaf IS the root
    function test_singleLeafEmptyProof() public {
        PassLedgerOracle.RewardClaim memory c = _claim(7 ether, PassLedgerOracle.ClaimType.FEE);
        fsm.setRoot(EPOCH, _leaf(c));
        oracle.postWithProof(c, new bytes32[](0));
        assertEq(oracle.provenTrailingFee(PROVIDER), 7 ether);
    }
}
