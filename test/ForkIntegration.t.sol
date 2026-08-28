// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {IPChainStakeMirror} from "../src/interfaces/IPChainStakeMirror.sol";
import {MockERC20} from "./mocks/Tokens.sol";

/// End-to-end integration against the REAL Coston2 contracts on a fork:
/// real WNat (margin, delegation-back, wrap-on-sweep) and real FtsoV2
/// (fixed-dollar pricing). Only the stablecoin is a mock (test accounts hold
/// no USDT0). Skips automatically if no Coston2 RPC is configured.
///
/// Run: forge test --match-contract ForkIntegration
contract ForkIntegrationTest is Test {
    address constant WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;
    address constant CSM = 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e;
    address constant FTSOV2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    address constant REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);

    LoanVault vault;
    PassLedgerOracle oracle;
    MockERC20 usd;
    IWNat wnat = IWNat(WNAT);

    address keeper = makeAddr("keeper");
    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    uint64 epoch = 1000;

    bool forked;

    function setUp() public {
        try vm.createSelectFork("coston2") {
            forked = true;
        } catch {
            forked = false; // no RPC configured -> tests below no-op
            return;
        }
        usd = new MockERC20("USDT0");
        oracle = new PassLedgerOracle(keeper, IFlareContractRegistry(REGISTRY), 8);
        vault = new LoanVault(
            LoanVault.Config({
                usd: IERC20(address(usd)),
                wnat: wnat,
                oracle: oracle,
                claimSetupManager: CSM,
                keeperExecutor: keeper,
                epochDurationSeconds: 21_600,
                ftso: IFtsoV2(FTSOV2),
                pchainMirror: IPChainStakeMirror(0xd2a1Bb23eB350814a30Dd6f9de78Bb2C8fdD9F1D),
                flrUsdFeedId: FLR_USD,
                maxPriceDeviationBps: 0, // band is unit-tested; this test is
                    // about the real WNat/FtsoV2 integration + lifecycle
                minSettledEpochs: 10,
                deadEpochsToTrigger: 4,
                gracePeriod: 7 days,
                maxPriceAge: 365 days, // fork time can drift from feed ts
                requireProvenTrailing: false
            })
        );
        usd.mint(lender, 1_000e6);
        vm.deal(borrower, 10_000 ether); // native C2FLR to wrap
        vm.prank(lender);
        usd.approve(address(vault), type(uint256).max);
    }

    function _postAlive() internal {
        vm.prank(keeper);
        oracle.post(borrower, ++epoch, 400 ether, 3, 20, true);
    }

    function _postDead() internal {
        vm.prank(keeper);
        oracle.post(borrower, ++epoch, 400 ether, 3, 20, false);
    }

    // fixed-FLR: full circle against real WNat, real delegation, real sweep
    function test_fork_fixedFlr_fullCircle() public {
        if (!forked) return;
        _postAlive();
        vm.prank(lender);
        uint256 id = vault.offer(borrower, false, 1_000e6, 1_000 ether, 2_000 ether, 10 ether, 500, 4);
        vm.startPrank(borrower);
        vault.accept(id);
        wnat.deposit{value: 2_000 ether}(); // wrap on REAL WNat
        wnat.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();

        // escrow delegates its whole balance back to the borrower on real WNat
        address escrow = address(vault.getLoan(id).escrow);
        assertEq(wnat.balanceOf(escrow), 2_000 ether);

        // 4 reward sweeps of 300 FLR each through the real collector
        RewardCollector collector = vault.getLoan(id).collector;
        for (uint256 i; i < 4; i++) {
            _postAlive(); // an epoch passes -> interest accrues at the pass-rate
            vm.deal(address(collector), 300 ether);
            collector.sweep(); // wraps native on real WNat, repays vault
            if (vault.statusOf(id) == 6) break;
        }
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        // conservation: after both parties pull their credits, the vault and
        // the escrow hold nothing.
        vm.prank(lender);
        vault.withdraw(WNAT);
        vm.prank(borrower);
        vault.withdraw(WNAT);
        assertEq(wnat.balanceOf(address(vault)), 0);
        assertEq(wnat.balanceOf(escrow), 0);
        assertGt(wnat.balanceOf(lender), 1_000 ether); // principal + interest
    }

    // fixed-dollar: priced by the REAL FtsoV2 feed
    function test_fork_fixedDollar_pricedByRealFtso() public {
        if (!forked) return;
        _postAlive();
        // line valued at real price; keep debt tiny so it always fits
        vm.prank(lender);
        uint256 id = vault.offer(borrower, true, 1e6, 1e6, 2_000 ether, 0.1e6, 500, 4);
        vm.startPrank(borrower);
        vault.accept(id); // reads the REAL FLR/USD feed
        wnat.deposit{value: 2_500 ether}(); // 2000 margin + 500 for repayment
        wnat.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id); // pulls exactly 2000, leaving 500 WFLR
        vault.draw(id);
        // repay in FLR valued at the real price until cleared
        for (uint256 i; i < 8 && vault.statusOf(id) != 6; i++) {
            vault.repay(id, 200 ether);
        }
        vm.stopPrank();
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
    }

    // the SelfLend pattern: ONE wallet is both lender and borrower, with real
    // USDT0 (via deal) — validates script/SelfLend.s.sol before a real run.
    function test_fork_selfLend_oneWalletBothParties() public {
        if (!forked) return;
        address me = makeAddr("selfLender");
        deal(address(usd), me, 5e6); // stand-in for faucet USDT0 (mock usd here)
        vm.deal(me, 1_000 ether); // C2FLR for margin + wrap

        vm.startPrank(me);
        oracle = new PassLedgerOracle(me, IFlareContractRegistry(REGISTRY), 8);
        LoanVault v = new LoanVault(
            LoanVault.Config({
                usd: IERC20(address(usd)),
                wnat: wnat,
                oracle: oracle,
                claimSetupManager: CSM,
                keeperExecutor: me,
                epochDurationSeconds: 21_600,
                ftso: IFtsoV2(FTSOV2),
                pchainMirror: IPChainStakeMirror(0xd2a1Bb23eB350814a30Dd6f9de78Bb2C8fdD9F1D),
                flrUsdFeedId: FLR_USD,
                maxPriceDeviationBps: 0,
                minSettledEpochs: 10,
                deadEpochsToTrigger: 4,
                gracePeriod: 7 days,
                maxPriceAge: 365 days,
                requireProvenTrailing: false
            })
        );
        oracle.post(me, 1000, 100 ether, 3, 20, true);
        usd.approve(address(v), type(uint256).max);
        // $1 debt needs margin worth ~$2 => ~400 FLR at the real ~$0.0065 price
        uint256 id = v.offer(me, true, 1e6, 1e6, 400 ether, 0.1e6, 500, 4);
        v.accept(id);
        wnat.deposit{value: 600 ether}(); // 400 margin + 200 repay buffer
        wnat.approve(address(v), type(uint256).max);
        v.fund(id);
        v.postMargin(id); // takes 400, leaves 200 WFLR
        v.draw(id);
        assertEq(usd.balanceOf(me), 5e6); // 5 held - 1 lent + 1 borrowed back = 5
        // repay the $1 debt in FLR at the real price (~154 FLR)
        v.repay(id, 200 ether);
        vm.stopPrank();
        assertEq(uint8(v.getLoan(id).status), uint8(LoanVault.Status.Repaid));
    }

    // default -> settle, and a lender-position transfer mid-loan
    function test_fork_defaultAndLenderTransfer() public {
        if (!forked) return;
        _postAlive();
        vm.prank(lender);
        uint256 id = vault.offer(borrower, false, 1_000e6, 1_000 ether, 2_000 ether, 10 ether, 500, 100);
        vm.startPrank(borrower);
        vault.accept(id);
        wnat.deposit{value: 2_000 ether}();
        wnat.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();

        // lender sells the position to a buyer
        address buyer = makeAddr("buyer");
        vm.prank(lender);
        vault.transferLender(id, buyer);

        // validator dies -> trip -> grace -> settle; recovery goes to the BUYER
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        uint256 due = vault.getLoan(id).outstanding + 10 ether;
        vm.warp(block.timestamp + 7 days);
        vault.settle(id);
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Settled));
        assertEq(vault.owed(buyer, address(wnat)), due); // buyer recovers, not the seller
        assertEq(vault.owed(lender, address(wnat)), 0);
    }
}
