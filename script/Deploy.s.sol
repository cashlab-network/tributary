// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {PassLedgerOracle} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {MockERC20} from "../test/mocks/Tokens.sol";

/// Deploys the Tributary v1 stack to Coston2 (or a fork of it).
/// WNat is the REAL chain contract, read from the FlareContractRegistry
/// (0xC67D... on Coston2, chain 114); the stablecoin is a mock on testnet
/// because USDT0 does not exist there.
contract Deploy is Script {
    address constant COSTON2_WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;

    function run() external returns (LoanVault vault, PassLedgerOracle oracle, MockERC20 usd) {
        address wnat = vm.envOr("WNAT_ADDRESS", COSTON2_WNAT);
        vm.startBroadcast();
        usd = new MockERC20("Testnet USD (mock)");
        oracle = new PassLedgerOracle(msg.sender);
        vault = new LoanVault(IERC20(address(usd)), IWNat(wnat), oracle, 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e, msg.sender, 21_600);
        vm.stopBroadcast();
        console2.log("WNat (chain):", wnat);
        console2.log("Mock USD:   ", address(usd));
        console2.log("Oracle:     ", address(oracle));
        console2.log("LoanVault:  ", address(vault));
    }
}
