// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {LoanVault} from "../src/LoanVault.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {LoanVaultTestBase} from "./LoanVault.t.sol";

/// The fixed-dollar flavor: borrower owes DOLLARS, repays in FLR valued at
/// the FTSO price per repayment. Borrower keeps upside; lender gets downside
/// protection. MockFtso starts at $0.02/FLR (2_000_000 @ 8 decimals).
contract FixedDollarTest is LoanVaultTestBase {
    uint256 constant DEBT_USD = 1_000e6; // owes $1,000

    function _offerUsd() internal returns (uint256 id) {
        // line: min(70% x 20k x 4, 50% x 100k) = 50k FLR = $1,000 at $0.02
        vm.prank(lender);
        id = vault.offer(borrower, true, PRINCIPAL_USD, DEBT_USD, MARGIN, 10e6, BENCHMARK_BPS, TERM_EPOCHS);
    }

    function _openAndDrawUsd() internal returns (uint256 id) {
        id = _offerUsd();
        vm.prank(borrower);
        vault.accept(id);
        vm.prank(lender);
        vault.fund(id);
        vm.startPrank(borrower);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopPrank();
    }

    // --- underwriting values the line in dollars ---

    function test_accept_dualCapValuedAtOracle() public {
        // line is exactly $1,000 at $0.02 — $1,000 debt passes...
        uint256 id = _openAndDrawUsd();
        assertEq(vault.getLoan(id).outstanding, DEBT_USD);
    }

    function test_accept_debtAboveDollarLineReverts() public {
        vm.prank(lender);
        uint256 id = vault.offer(borrower, true, PRINCIPAL_USD, 1_001e6, MARGIN, 10e6, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.ExceedsCreditLine.selector, 1_001e6, 1_000e6));
        vm.prank(borrower);
        vault.accept(id);
    }

    // --- repayment valued at the oracle, borrower keeps upside ---

    function test_repay_valuedAtPrice() public {
        uint256 id = _openAndDrawUsd();
        vm.prank(borrower);
        vault.repay(id, 25_000 ether); // $500 at $0.02
        assertEq(vault.getLoan(id).outstanding, 500e6);
        assertEq(vault.owed(lender, address(wnat)), 25_000 ether);
    }

    function test_priceRise_meansFewerCoins() public {
        uint256 id = _openAndDrawUsd();
        vm.prank(borrower);
        vault.repay(id, 25_000 ether); // $500 down at $0.02
        ftso.set(4_000_000, 8); // FLR doubles to $0.04
        vm.prank(borrower);
        vault.repay(id, 12_500 ether); // the remaining $500 costs HALF the coins
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        // borrower repaid $1,000 with 37,500 FLR instead of 50,000 — upside kept
        assertEq(vault.owed(lender, address(wnat)), 37_500 ether);
        assertEq(vault.owed(borrower, address(wnat)), MARGIN); // margin released
    }

    function test_overpay_excessReturnsAtPrice() public {
        uint256 id = _openAndDrawUsd();
        ftso.set(4_000_000, 8);
        vm.prank(borrower);
        vault.repay(id, 30_000 ether); // $1,200 offered vs $1,000 owed
        assertEq(uint8(vault.getLoan(id).status), uint8(LoanVault.Status.Repaid));
        // lender receives exactly $1,000 worth: 25,000 FLR at $0.04
        assertEq(vault.owed(lender, address(wnat)), 25_000 ether);
        assertEq(vault.owed(borrower, address(wnat)), 5_000 ether + MARGIN);
    }

    // --- settlement converts the dollar debt at the oracle ---

    function test_settle_convertsDueAtPrice() public {
        uint256 id = _openAndDrawUsd();
        for (uint256 i; i < 4; i++) _postDead();
        vault.trip(id);
        uint256 outstandingUsd = vault.getLoan(id).outstanding; // accrued through trip
        vm.warp(block.timestamp + 7 days);
        vault.settle(id);
        // due = (outstanding + $10 fee) at $0.02 -> FLR, ceil
        uint256 dueFlr = (outstandingUsd + 10e6) * 1e8 * 1e12 / 2_000_000
            + ((outstandingUsd + 10e6) * 1e8 * 1e12 % 2_000_000 == 0 ? 0 : 1);
        assertEq(vault.owed(lender, address(wnat)), dueFlr);
        assertEq(vault.owed(borrower, address(wnat)), MARGIN - dueFlr);
    }

    // --- price hygiene ---

    function test_stalePriceReverts() public {
        uint256 id = _offerUsd();
        vm.warp(block.timestamp + 10 hours);
        ftso.setTimestamp(uint64(block.timestamp - 2 hours)); // older than maxPriceAge
        vm.expectRevert(abi.encodeWithSelector(LoanVault.StalePrice.selector, uint64(block.timestamp - 2 hours)));
        vm.prank(borrower);
        vault.accept(id);
    }

    function test_fixedDollarOfferWithoutFtsoReverts() public {
        LoanVault.Config memory cfg = _config(0);
        cfg.ftso = IFtsoV2(address(0));
        LoanVault noFtso = new LoanVault(cfg);
        vm.expectRevert(LoanVault.PriceUnavailable.selector);
        vm.prank(lender);
        noFtso.offer(borrower, true, PRINCIPAL_USD, DEBT_USD, MARGIN, 10e6, BENCHMARK_BPS, TERM_EPOCHS);
    }
}

/// The G13 band: a consented fixed-FLR pair whose implied price strays too
/// far from the oracle must be refused at accept.
contract PriceBandTest is LoanVaultTestBase {
    LoanVault banded;

    function setUp() public override {
        super.setUp();
        banded = new LoanVault(_config(2_500)); // ±25% band
        vm.prank(lender);
        usd.approve(address(banded), type(uint256).max);
        vm.prank(borrower);
        wnat.approve(address(banded), type(uint256).max);
    }

    function test_pairInsideBandPasses() public {
        // $1,000 for 50,000 FLR implies $0.02 — exactly the oracle price
        vm.prank(lender);
        uint256 id = banded.offer(borrower, false, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.prank(borrower);
        banded.accept(id);
        assertEq(uint8(banded.getLoan(id).status), uint8(LoanVault.Status.Open));
    }

    function test_fatFingeredPairReverts() public {
        // $1,000 for 5,000 FLR implies $0.20 — 10x the oracle: refuse
        vm.prank(lender);
        uint256 id = banded.offer(borrower, false, PRINCIPAL_USD, 5_000 ether, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.expectRevert(abi.encodeWithSelector(LoanVault.PriceOutOfBand.selector, 20_000_000, 2_000_000));
        vm.prank(borrower);
        banded.accept(id);
    }
}
