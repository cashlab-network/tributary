// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TermsLib} from "../src/TermsLib.sol";

contract TermsLibTest is Test {
    // --- creditLine: the dual cap ---

    function test_creditLine_streamCapBinds() public pure {
        // 100 FLR/epoch, 4 epochs, huge margin: line = 70% * 400 = 280
        uint256 line = TermsLib.creditLine(100 ether, 4, 10_000 ether);
        assertEq(line, 280 ether);
    }

    function test_creditLine_marginCapBinds() public pure {
        // huge stream, 100 FLR margin: line = 50% * 100 = 50
        uint256 line = TermsLib.creditLine(1000 ether, 10, 100 ether);
        assertEq(line, 50 ether);
    }

    function test_creditLine_zeroStreamMeansZeroLine() public pure {
        // no trailing record -> no credit, regardless of margin
        assertEq(TermsLib.creditLine(0, 10, 1000 ether), 0);
    }

    function testFuzz_creditLine_neverExceedsEitherCap(uint96 perEpoch, uint8 term, uint96 margin) public pure {
        uint256 line = TermsLib.creditLine(perEpoch, term, margin);
        assertLe(line, (uint256(perEpoch) * term * 7000) / 10_000);
        assertLe(line, (uint256(margin) * 5000) / 10_000);
    }

    // --- rateBps: benchmark + 4 - 1/pass, floor benchmark + 1 ---

    function test_rateBps_zeroPasses() public pure {
        assertEq(TermsLib.rateBps(500, 0), 900); // benchmark + 4pts
    }

    function test_rateBps_threePassesHitsFloor() public pure {
        assertEq(TermsLib.rateBps(500, 3), 600); // benchmark + 1pt floor
    }

    function test_rateBps_passCountAboveLedgerMaxClamps() public pure {
        // defensive clamp: a corrupt pass count must not push below the floor
        assertEq(TermsLib.rateBps(500, 200), 600);
    }

    function testFuzz_rateBps_neverBelowLenderAlternative(uint32 benchmark, uint8 passes) public pure {
        // the Anchor rule: never price below the lender's passive alternative
        assertGe(TermsLib.rateBps(benchmark, passes), uint256(benchmark) + 100);
    }

    // --- applyRepayment: the H-06 cap ---

    function test_applyRepayment_overpaymentBecomesChange() public pure {
        // the Debt DAO H-06 failing case: pay 150 against 100 outstanding
        (uint256 applied, uint256 excess) = TermsLib.applyRepayment(100, 150);
        assertEq(applied, 100);
        assertEq(excess, 50);
    }

    function test_applyRepayment_exactPayoff() public pure {
        (uint256 applied, uint256 excess) = TermsLib.applyRepayment(100, 100);
        assertEq(applied, 100);
        assertEq(excess, 0);
    }

    function testFuzz_applyRepayment_neverUnderflows(uint256 outstanding, uint256 amount) public pure {
        (uint256 applied, uint256 excess) = TermsLib.applyRepayment(outstanding, amount);
        assertLe(applied, outstanding); // subtraction is always safe
        assertEq(applied + excess, amount); // conservation: nothing minted or lost
    }
}
