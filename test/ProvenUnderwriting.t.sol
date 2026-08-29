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
/// line off Merkle-PROVEN FEE rewards over a beneficiary-DECLARED recent window,
/// not the trusted poster's figure. The poster can still lie about the trailing
/// number in the trusted lane — but a vault in this mode ignores it entirely.
///
/// REVIEW4-MA hardening covered here: FEE proofs are self-sovereign; the window
/// is re-declarable (no self-lockout); a stale window fails safe; cherry-picking
/// (skipping weak epochs) is impossible.
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
    uint32 constant WINDOW = 4; // minTrailingWindow

    function setUp() public {
        usd = new MockERC20("USDT0");
        wnat = new MockWNat();
        csm = new MockCSM();
        ftso = new MockFtso();
        fsm = new MockFSM();
        registry = new MockRegistry(address(fsm));
        // minTrailingWindow = 4: a nonzero trailing needs 4 contiguous proven epochs
        oracle = new PassLedgerOracle(address(this), IFlareContractRegistry(address(registry)), WINDOW);
        // "now" for recency: windows ending at 5991 are recent (current-end <= 4)
        fsm.setCurrentEpoch(5992);

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

    /// Build a real (mock-signed) FEE claim + proof for `who`. Returns the claim
    /// and proof so tests can also submit them from OTHER callers.
    function _feeClaim(address who, uint24 epochId, uint120 amount)
        internal
        returns (PassLedgerOracle.RewardClaim memory c, bytes32[] memory proof)
    {
        c = PassLedgerOracle.RewardClaim({
            rewardEpochId: epochId,
            beneficiary: bytes20(who),
            amount: amount,
            claimType: PassLedgerOracle.ClaimType.FEE
        });
        bytes32 leaf = keccak256(abi.encode(c));
        bytes32 sib = keccak256(abi.encode("sib", epochId));
        bytes32 root = leaf <= sib ? keccak256(abi.encodePacked(leaf, sib)) : keccak256(abi.encodePacked(sib, leaf));
        fsm.setRoot(epochId, root);
        proof = new bytes32[](1);
        proof[0] = sib;
    }

    // borrower proves one of their own FEE epochs (REVIEW4-MA: self-sovereign)
    function _proveFee(uint24 epochId, uint120 amount) internal {
        (PassLedgerOracle.RewardClaim memory c, bytes32[] memory proof) = _feeClaim(borrower, epochId, amount);
        vm.prank(borrower);
        oracle.postWithProof(c, proof);
    }

    // borrower declares which recent contiguous window underwrites their loan
    function _declare(uint24 end) internal {
        vm.prank(borrower);
        oracle.declareTrailingWindow(end);
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
        // prove a CONTIGUOUS 4-epoch window averaging 10,000 FLR, declare it ->
        // line = 70% * 10k * 4 = 28,000 FLR (margin cap 50k doesn't bind)
        _proveFee(5988, 8_000 ether);
        _proveFee(5989, 12_000 ether);
        _proveFee(5990, 9_000 ether);
        _proveFee(5991, 11_000 ether); // sum 40k / 4 = 10k
        _declare(5991);
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
    // inflate the line — you cannot declare a window you haven't fully proven.
    function test_cherryPickSinglePeak_cannotDeclare_givesZeroLine() public {
        _proveFee(5991, 999_999 ether); // one huge real epoch, nothing else
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(PassLedgerOracle.WindowNotProven.selector, uint24(5988)));
        oracle.declareTrailingWindow(5991); // window [5988..5991] not fully proven
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 0); // no window declared

        vm.prank(lender);
        uint256 id = vault.offer(borrower, false, PRINCIPAL_USD, 1 ether, MARGIN, 0, 500, TERM);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 1 ether, 0));
        vm.prank(borrower);
        vault.accept(id);
    }

    // A gap in the window (skip a weak epoch, keep the strong ones) can't be
    // declared — contiguity is enforced at declare.
    function test_gapInWindow_cannotDeclare() public {
        _proveFee(5988, 12_000 ether);
        _proveFee(5989, 12_000 ether);
        _proveFee(5990, 12_000 ether);
        _proveFee(5992, 12_000 ether); // skipped 5991
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(PassLedgerOracle.WindowNotProven.selector, uint24(5991)));
        oracle.declareTrailingWindow(5992);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 0);
    }

    // Proving the FULL contiguous window including the weak epochs gives the
    // honest lower average — you cannot escape your bad epochs.
    function test_fullWindowIncludesWeakEpochs() public {
        _proveFee(5988, 1_000 ether);
        _proveFee(5989, 1_000 ether);
        _proveFee(5990, 1_000 ether);
        _proveFee(5991, 12_000 ether); // one spike; honest avg = 3,750
        _declare(5991);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 3_750 ether);
    }

    // ------------------------------------------------------------ REVIEW4-MA

    // GRIEF, blocked (barrier 1 — self-sovereign records): a stranger with a
    // VALID proof of the borrower's own real reward cannot write it.
    function test_grief_thirdPartyFeeProof_reverts() public {
        _proveFee(5988, 10_000 ether);
        _proveFee(5989, 10_000 ether);
        _proveFee(5990, 10_000 ether);
        _proveFee(5991, 10_000 ether);
        _declare(5991);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether);

        // attacker builds a VALID claim+proof for the borrower's real epoch 5999
        (PassLedgerOracle.RewardClaim memory c, bytes32[] memory proof) = _feeClaim(borrower, 5999, 1 ether);
        vm.prank(makeAddr("griefer"));
        vm.expectRevert(PassLedgerOracle.NotBeneficiary.selector);
        oracle.postWithProof(c, proof);

        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether); // untouched
    }

    // SELF-LOCKOUT FIXED (the whole point of the redesign): proving a distant
    // epoch no longer poisons the window. Under the old cumulative aggregate
    // this zeroed the borrower FOREVER; now they just point at the good window.
    function test_selfLockout_fixed_distantEpochDoesNotPoison() public {
        _proveFee(5988, 10_000 ether);
        _proveFee(5989, 10_000 ether);
        _proveFee(5990, 10_000 ether);
        _proveFee(5991, 10_000 ether);
        _proveFee(5999, 1 ether); // borrower's own distant epoch, later
        _declare(5991); // still declarable — window is unaffected
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether);
    }

    // RE-DECLARABLE (repeat borrower): prove a fresh newer window and switch to
    // it — never locked to the first one.
    function test_redeclare_freshWindow() public {
        _proveFee(5988, 10_000 ether);
        _proveFee(5989, 10_000 ether);
        _proveFee(5990, 10_000 ether);
        _proveFee(5991, 10_000 ether);
        _declare(5991);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether);

        // time passes; borrower proves a newer window and re-declares
        fsm.setCurrentEpoch(5997);
        _proveFee(5993, 20_000 ether);
        _proveFee(5994, 20_000 ether);
        _proveFee(5995, 20_000 ether);
        _proveFee(5996, 20_000 ether);
        _declare(5996);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 20_000 ether);
    }

    // RECENCY (closes LOW-2): a window that is no longer recent fails safe to 0,
    // so a borrower can't underwrite off a stale historical peak.
    function test_staleWindow_failsSafeToZero() public {
        _proveFee(5988, 10_000 ether);
        _proveFee(5989, 10_000 ether);
        _proveFee(5990, 10_000 ether);
        _proveFee(5991, 10_000 ether);
        _declare(5991);
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether);

        // the chain moves far past the window end -> stale -> 0
        fsm.setCurrentEpoch(uint24(5991 + WINDOW + 1));
        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 0);
    }

    // Non-FEE claim types stay permissionless and cannot touch the FEE window.
    function test_nonFeeProof_staysPermissionless() public {
        _proveFee(5988, 10_000 ether);
        _proveFee(5989, 10_000 ether);
        _proveFee(5990, 10_000 ether);
        _proveFee(5991, 10_000 ether);
        _declare(5991);

        PassLedgerOracle.RewardClaim memory c = PassLedgerOracle.RewardClaim({
            rewardEpochId: 5999,
            beneficiary: bytes20(borrower),
            amount: 1 ether,
            claimType: PassLedgerOracle.ClaimType.WNAT
        });
        bytes32 leaf = keccak256(abi.encode(c));
        bytes32 sib = keccak256(abi.encode("sib-wnat", uint24(5999)));
        bytes32 root = leaf <= sib ? keccak256(abi.encodePacked(leaf, sib)) : keccak256(abi.encodePacked(sib, leaf));
        fsm.setRoot(5999, root);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sib;

        vm.prank(makeAddr("anyone"));
        oracle.postWithProof(c, proof); // permissionless: no revert

        assertEq(oracle.provenTrailingFee(bytes20(borrower)), 10_000 ether); // FEE window untouched
    }
}
