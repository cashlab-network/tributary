// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {MockERC20} from "../test/mocks/Tokens.sol";

/// Full life-of-a-loan demo against the REAL WNat on a Coston2 fork.
/// Three anvil accounts play the parts:
///   account 0 — deployer + oracle poster + keeper
///   account 1 — lender (brings mock USD)
///   account 2 — borrower (a validator entity; native C2FLR stands in for
///               its reward stream, delivered to the collector each "epoch")
/// Run:
///   anvil --fork-url https://coston2-api.flare.network/ext/C/rpc
///   forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract Demo is Script {
    address constant COSTON2_WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;

    // anvil's standard, publicly-known dev keys
    uint256 constant KEEPER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant LENDER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant BORROWER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    uint256 constant PRINCIPAL_USD = 1_000e6; // 1,000 mock-USD advanced
    uint256 constant DEBT_FLR = 1_000 ether; // fixed-FLR debt (forward price)
    uint256 constant MARGIN = 2_000 ether; // 2x in WFLR
    uint256 constant DEFAULT_FEE = 10 ether;
    uint256 constant BENCHMARK_BPS = 500; // 5% staking-yield benchmark
    uint16 constant TERM_EPOCHS = 4;
    uint192 constant TRAILING = 400 ether; // trailing rewards per epoch
    uint256 constant EPOCH_REWARD = 300 ether; // what the stream delivers

    IWNat wnat = IWNat(COSTON2_WNAT);
    uint64 epoch = 1000;

    function run() external {
        address keeper = vm.addr(KEEPER_PK);
        address lender = vm.addr(LENDER_PK);
        address borrower = vm.addr(BORROWER_PK);

        // -- deploy + seed the ledger (keeper is poster)
        vm.startBroadcast(KEEPER_PK);
        MockERC20 usd = new MockERC20("Testnet USD (mock)");
        PassLedgerOracle oracle = new PassLedgerOracle(keeper);
        LoanVault vault = new LoanVault(IERC20(address(usd)), wnat, oracle);
        usd.mint(lender, PRINCIPAL_USD);
        oracle.post(borrower, ++epoch, TRAILING, 3, 20, true); // 3/3 passes, 20 settled epochs
        vm.stopBroadcast();
        console2.log("deployed vault:", address(vault));

        // -- lender offers + funds
        vm.startBroadcast(LENDER_PK);
        usd.approve(address(vault), type(uint256).max);
        uint256 id = vault.offer(borrower, PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS);
        vm.stopBroadcast();
        console2.log("loan offered, id:", id);

        // -- borrower underwrites against the ledger, posts margin, draws
        vm.startBroadcast(BORROWER_PK);
        vault.accept(id); // underwriting happens HERE, on real ledger data
        wnat.deposit{value: MARGIN}(); // wrap native C2FLR on the REAL WNat
        wnat.approve(address(vault), type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(LENDER_PK);
        vault.fund(id);
        vm.stopBroadcast();

        vm.startBroadcast(BORROWER_PK);
        vault.postMargin(id);
        vault.draw(id);
        vm.stopBroadcast();
        console2.log("drawn. borrower USD balance:", usd.balanceOf(borrower));
        console2.log("escrow delegating to borrower on real WNat:", address(vault.getLoan(id).escrow));

        // -- epochs pass: the stream lands on the collector, keeper sweeps
        RewardCollector collector = vault.getLoan(id).collector;
        for (uint256 i = 1; i <= 4; i++) {
            vm.startBroadcast(BORROWER_PK); // stand-in for the reward manager claim
            (bool ok,) = address(collector).call{value: EPOCH_REWARD}("");
            require(ok, "reward transfer failed");
            vm.stopBroadcast();

            vm.startBroadcast(KEEPER_PK);
            oracle.post(borrower, ++epoch, TRAILING, 3, 20, true);
            collector.sweep(); // wraps native on real WNat, repays the vault
            vm.stopBroadcast();

            uint8 status = vault.statusOf(id);
            console2.log("epoch swept:", i);
            if (status == 6) {
                console2.log("loan REPAID at sweep", i);
                break;
            }
            console2.log("  outstanding FLR:", vault.getLoan(id).outstandingFlr);
        }

        // -- everyone withdraws their pull balances
        vm.startBroadcast(LENDER_PK);
        vault.withdraw(address(wnat));
        vm.stopBroadcast();
        vm.startBroadcast(BORROWER_PK);
        vault.withdraw(address(wnat)); // released margin + change
        vm.stopBroadcast();

        console2.log("=== FINAL ===");
        console2.log("status (6 = Repaid):", vault.statusOf(id));
        console2.log("lender WFLR received:", wnat.balanceOf(lender));
        console2.log("borrower WFLR (margin back + change):", wnat.balanceOf(borrower));
        console2.log("borrower still holds USD:", usd.balanceOf(borrower));
        console2.log("vault residual WFLR (must be 0):", wnat.balanceOf(address(vault)));
    }
}
