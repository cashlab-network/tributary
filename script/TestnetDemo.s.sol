// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {MockERC20} from "../test/mocks/Tokens.sol";

/// Life-of-a-loan on the REAL Coston2 testnet, sized to one faucet drip
/// (100 C2FLR). Two throwaway keys from .env:
///   DEPLOYER_PK — deployer + oracle poster + keeper + lender
///   BORROWER_PK — the borrower (funded by a transfer from the deployer)
/// Run:
///   source .env && forge script script/TestnetDemo.s.sol \
///     --rpc-url coston2 --broadcast --gas-estimate-multiplier 300 --slow
contract TestnetDemo is Script {
    address constant COSTON2_WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;

    // Faucet-drip-sized terms: 10 FLR debt, 20 FLR margin (2x), ~12 FLR stream
    uint256 constant PRINCIPAL_USD = 10e6; // 10 mock-USD advanced
    uint256 constant DEBT_FLR = 10 ether;
    uint256 constant MARGIN = 20 ether;
    uint256 constant DEFAULT_FEE = 0.1 ether;
    uint256 constant BENCHMARK_BPS = 500;
    uint16 constant TERM_EPOCHS = 4;
    uint192 constant TRAILING = 4 ether;
    uint256 constant EPOCH_REWARD = 3 ether;

    IWNat wnat = IWNat(COSTON2_WNAT);

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 borrowerPk = vm.envUint("BORROWER_PK");
        address deployer = vm.addr(deployerPk);
        address borrower = vm.addr(borrowerPk);
        uint64 epoch = uint64(vm.envOr("START_EPOCH", uint256(1)));

        // -- deploy + seed: deployer is poster, keeper AND lender
        vm.startBroadcast(deployerPk);
        MockERC20 usd = new MockERC20("Testnet USD (mock)");
        PassLedgerOracle oracle = new PassLedgerOracle(deployer);
        LoanVault vault = new LoanVault(IERC20(address(usd)), wnat, oracle, 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e, deployer, 21_600);
        usd.mint(deployer, PRINCIPAL_USD);
        oracle.post(borrower, ++epoch, TRAILING, 3, 20, true);
        usd.approve(address(vault), type(uint256).max);
        uint256 id = vault.offer(borrower, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        // margin + "reward stream" + a generous gas cushion for the borrower
        payable(borrower).transfer(MARGIN + 20 ether);
        vm.stopBroadcast();
        console2.log("vault:", address(vault));
        console2.log("oracle:", address(oracle));
        console2.log("loan id:", id);

        // -- borrower: underwrite, margin, draw
        vm.startBroadcast(borrowerPk);
        vault.accept(id);
        wnat.deposit{value: MARGIN}();
        wnat.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(deployerPk);
        vault.fund(id);
        vm.stopBroadcast();

        vm.startBroadcast(borrowerPk);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopBroadcast();
        console2.log("drawn; borrower USD:", usd.balanceOf(borrower));

        // -- four epochs of stream -> sweep
        RewardCollector collector = vault.getLoan(id).collector;
        console2.log("collector:", address(collector));
        for (uint256 i = 1; i <= 4; i++) {
            vm.startBroadcast(borrowerPk);
            (bool ok,) = address(collector).call{value: EPOCH_REWARD}("");
            require(ok, "reward transfer failed");
            vm.stopBroadcast();

            vm.startBroadcast(deployerPk);
            oracle.post(borrower, ++epoch, TRAILING, 3, 20, true);
            collector.sweep();
            vm.stopBroadcast();
            console2.log("sweep", i, "outstanding:", vault.getLoan(id).outstandingFlr);
            if (vault.statusOf(id) == 6) break;
        }

        vm.startBroadcast(deployerPk);
        vault.withdraw(address(wnat)); // lender leg
        vm.stopBroadcast();
        vm.startBroadcast(borrowerPk);
        vault.withdraw(address(wnat)); // margin back + change
        vm.stopBroadcast();

        console2.log("=== FINAL (verify on coston2-explorer.flare.network) ===");
        console2.log("status (6 = Repaid):", vault.statusOf(id));
        console2.log("lender WFLR:", wnat.balanceOf(deployer));
        console2.log("borrower WFLR:", wnat.balanceOf(borrower));
        console2.log("vault residual (0):", wnat.balanceOf(address(vault)));
    }
}
