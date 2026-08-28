// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {IPChainStakeMirror} from "../src/interfaces/IPChainStakeMirror.sol";
import {MockERC20, MockWNat, MockCSM, MockFtso, MockFSM, MockRegistry} from "./mocks/Tokens.sol";

/// G1 end-to-end: a vault configured `requireProvenTrailing` sizes the credit
/// line off Merkle-PROVEN FEE rewards, not the trusted poster's figure. The
/// poster can still lie about the trailing number in the trusted lane — but a
/// vault in this mode ignores it entirely.
contract ProvenUnderwritingTest is Test {
    LoanVault vault;
    PassLedgerOracle oracle;
    MockERC20 usd;
    MockWNat wnat;
    MockCSM csm;
    MockFtso ftso;
    MockFSM fsm;
    MockRegistry registry;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");

    uint256 constant PRINCIPAL_USD = 1_000e6;
    uint256 constant MARGIN = 100_000 ether;
    uint16 constant TERM = 4;
    uint24 constant EPOCH = 5990;

    function setUp() public {
        usd = new MockERC20("USDT0");
        wnat = new MockWNat();
        csm = new MockCSM();
        ftso = new MockFtso();
        fsm = new MockFSM();
        registry = new MockRegistry(address(fsm));
        // minTrailingWindow = 4: a nonzero trailing needs 4 contiguous proven epochs
        oracle = new PassLedgerOracle(address(this), IFlareContractRegistry(address(registry)), 4);

        vault = new LoanVault(
            LoanVault.Config({
                usd: IERC20(address(usd)),
                wnat: IWNat(address(wnat)),
                oracle: oracle,
                claimSetupManager: address(csm),
                keeperExecutor: makeAddr("keeper"),
                epochDurationSeconds: 302_400,
                ftso: IFtsoV2(address(ftso)),
                pchainMirror: IPChainStakeMirror(address(0)),
                flrUsdFeedId: bytes21(uint168(1)),
                maxPriceDeviationBps: 0,
                minSettledEpochs: 10,
                deadEpochsToTrigger: 4,
                gracePeriod: 7 days,
                maxPriceAge: 1 hours,
                requireProvenTrailing: true // <-- trustless trailing
            })
        );

        usd.mint(lender, PRINCIPAL_USD);
        wnat.mint(borrower, MARGIN);
        vm.prank(lender);
        usd.approve(address(vault), type(uint256).max);
        vm.prank(borrower);
        wnat.approve(address(vault), type(uint256).max);

        // trusted lane still posts history/liveness (necessary — no on-chain
        // commitment for those), but the TRAILING it claims is a lie we ignore.
        oracle.post(borrower, 100, 999_999 ether /* lie */, 3, 20, true);
    }

    function _proveFee(uint24 epochId, uint120 amount) internal {
        PassLedgerOracle.RewardClaim memory c = PassLedgerOracle.RewardClaim({
            rewardEpochId: epochId,
            beneficiary: bytes20(borrower),
            amount: amount,
            claimType: PassLedgerOracle.ClaimType.FEE
        });
        bytes32 leaf = keccak256(abi.encode(c));
        bytes32 sib = keccak256(abi.encode("sib", epochId));
        bytes32 root = leaf <= sib ? keccak256(abi.encodePacked(leaf, sib)) : keccak256(abi.encodePacked(sib, leaf));
        fsm.setRoot(epochId, root);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;
        oracle.postWithProof(c, proof);
    }

    function test_noProvenData_lineIsZero_soAnyDebtReverts() public {
        // poster's lie (999_999 FLR trailing) must NOT create a credit line
        vm.prank(lender);
        uint256 id = vault.offer(borrower, false, PRINCIPAL_USD, 1 ether, MARGIN, 0, 500, TERM);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 1 ether, 0));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_provenTrailing_sizesTheLine() public {
        // prove a CONTIGUOUS 4-epoch window averaging 10,000 FLR -> line =
        // 70% * 10k * 4 = 28,000 FLR (margin cap 50k doesn't bind)
        _proveFee(5988, 8_000 ether);
        _proveFee(5989, 12_000 ether);
        _proveFee(5990, 9_000 ether);
        _proveFee(5991, 11_000 ether); // sum 40k / 4 = 10k
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether);

        vm.prank(lender);
        uint256 ok = vault.offer(borrower, false, PRINCIPAL_USD, 28_000 ether, MARGIN, 0, 500, TERM);
        vm.prank(borrower);
        vault.accept(ok);
        assertEq(uint8(vault.getLoan(ok).status), uint8(LoanVault.Status.Open));

        vm.prank(lender);
        uint256 tooBig = vault.offer(borrower, false, PRINCIPAL_USD, 28_001 ether, MARGIN, 0, 500, TERM);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 28_001 ether, 28_000 ether));
        vm.prank(borrower);
        vault.accept(tooBig);
    }

    // THE FIX (review-3 HIGH): cherry-picking a single peak epoch must NOT
    // inflate the line — too few proven epochs => 0 trailing => 0 line.
    function test_cherryPickSinglePeak_givesZeroLine() public {
        _proveFee(5991, 999_999 ether); // one huge real epoch, nothing else
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 0); // count 1 < window 4
        vm.prank(lender);
        uint256 id = vault.offer(borrower, false, PRINCIPAL_USD, 1 ether, MARGIN, 0, 500, TERM);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 1 ether, 0));
        vm.prank(borrower);
        vault.accept(id);
    }

    // A gap in the window (skip a weak epoch, keep the strong ones) must also
    // yield 0 — contiguity is required.
    function test_gapInWindow_givesZeroLine() public {
        _proveFee(5988, 12_000 ether);
        _proveFee(5989, 12_000 ether);
        _proveFee(5990, 12_000 ether);
        _proveFee(5992, 12_000 ether); // skipped 5991 -> count 4, span 5
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 0);
    }

    // Proving the FULL contiguous window including the weak epochs gives the
    // honest lower average — you cannot escape your bad epochs.
    function test_fullWindowIncludesWeakEpochs() public {
        _proveFee(5988, 1_000 ether);
        _proveFee(5989, 1_000 ether);
        _proveFee(5990, 1_000 ether);
        _proveFee(5991, 12_000 ether); // one spike; honest avg = 3,750
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 3_750 ether);
    }
}
