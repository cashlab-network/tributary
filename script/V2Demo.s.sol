// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle} from "../src/PassLedgerOracle.sol";
import {BorrowerAccount} from "../src/BorrowerAccount.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";

interface IClaimSetupManager {
    function setClaimExecutors(address[] calldata executors) external payable;
    function setAllowedClaimRecipients(address[] calldata recipients) external;
    function claimExecutors(address account) external view returns (address[] memory);
    function allowedClaimRecipients(address account) external view returns (address[] memory);
}

/// v2 on the REAL Coston2: a loan whose borrower is a claim-BOUND
/// BorrowerAccount, principal in REAL faucet USDT0, enrollment on the REAL
/// ClaimSetupManager. Leaves loan 2 live (Drawn, partially repaid, binding
/// active) as the standing exhibit.
/// Run: source .env, then
///   forge script script/V2Demo.s.sol --rpc-url coston2 --broadcast \
///     --gas-estimate-multiplier 300 --slow
contract V2Demo is Script {
    address constant WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;
    address constant USDT0 = 0xC1A5B41512496B80903D1f32d6dEa3a73212E71F; // faucet USDT0, 6dp
    address constant CSM = 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e;
    address constant ORACLE = 0xf941978Af75d17B7c5d4574CC04a4e07CE92D0B0; // deployed 2026-08-27

    uint256 constant PRINCIPAL_USD = 5e6; // 5 real USDT0
    uint256 constant DEBT_FLR = 10 ether;
    uint256 constant MARGIN = 20 ether;
    uint256 constant DEFAULT_FEE = 0.1 ether;
    uint256 constant BENCHMARK_BPS = 500;
    uint16 constant TERM_EPOCHS = 4;
    uint192 constant TRAILING = 4 ether;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 borrowerPk = vm.envUint("BORROWER_PK");
        address deployer = vm.addr(deployerPk);
        address borrowerEoa = vm.addr(borrowerPk);
        IWNat wnat = IWNat(WNAT);
        PassLedgerOracle oracle = PassLedgerOracle(ORACLE);

        // -- borrower deploys their account (their reward identity)
        vm.startBroadcast(borrowerPk);
        BorrowerAccount account = new BorrowerAccount(borrowerEoa);
        vm.stopBroadcast();
        console2.log("BorrowerAccount:", address(account));

        // -- deployer: vault2 on REAL USDT0 + ledger row for the account
        vm.startBroadcast(deployerPk);
        LoanVault vault2 = new LoanVault(IERC20(USDT0), wnat, oracle, CSM, deployer, 21_600);
        oracle.post(address(account), 100, TRAILING, 3, 20, true);
        IERC20(USDT0).approve(address(vault2), type(uint256).max);
        uint256 id = vault2.offer(
            address(account), PRINCIPAL_USD, DEBT_FLR, MARGIN, DEFAULT_FEE, BENCHMARK_BPS, TERM_EPOCHS
        );
        vm.stopBroadcast();
        console2.log("vault2 (real USDT0):", address(vault2));
        console2.log("loan id:", id);

        // -- borrower: move margin WFLR into the account, then drive the
        //    whole borrower side THROUGH the account (it is the borrower)
        vm.startBroadcast(borrowerPk);
        wnat.transfer(address(account), MARGIN);
        account.exec(address(vault2), 0, abi.encodeCall(LoanVault.accept, (id)));
        account.exec(WNAT, 0, abi.encodeCall(IERC20.approve, (address(vault2), type(uint256).max)));
        vm.stopBroadcast();

        vm.startBroadcast(deployerPk);
        vault2.fund(id);
        vm.stopBroadcast();

        RewardCollector collector = vault2.getLoan(id).collector;
        console2.log("collector:", address(collector));

        vm.startBroadcast(borrowerPk);
        account.exec(address(vault2), 0, abi.encodeCall(LoanVault.postMargin, (id)));
        account.exec(address(vault2), 0, abi.encodeCall(LoanVault.draw, (id)));

        // -- REAL enrollment on Flare's ClaimSetupManager, from the account:
        //    keeper is claim executor; the collector is the ONLY allowed
        //    off-account claim recipient. (Both lists are replace-all; this
        //    account has no prior settings to preserve.)
        address[] memory execs = new address[](1);
        execs[0] = deployer;
        address[] memory recips = new address[](1);
        recips[0] = address(collector);
        account.exec(CSM, 0, abi.encodeCall(IClaimSetupManager.setClaimExecutors, (execs)));
        account.exec(CSM, 0, abi.encodeCall(IClaimSetupManager.setAllowedClaimRecipients, (recips)));

        // -- BIND: from here the account cannot move value anywhere but the
        //    collector, and exec() reaches nothing (empty allowlist)
        account.bind(address(vault2), id, address(collector), new address[](0));

        // -- a "claimed reward" lands on the account; anyone routes + sweeps
        (bool ok,) = address(account).call{value: 3 ether}("");
        require(ok, "reward transfer failed");
        vm.stopBroadcast();

        vm.startBroadcast(deployerPk);
        oracle.post(address(account), 101, TRAILING, 3, 20, true);
        account.routeToCollector(address(0));
        collector.sweep();
        vm.stopBroadcast();

        console2.log("drawn + partially repaid. outstanding:", vault2.getLoan(id).outstandingFlr);
        console2.log("account USDT0 (the borrowed dollars):", IERC20(USDT0).balanceOf(address(account)));
        console2.log("bound:", account.bound());

        // (fence proof runs post-broadcast via eth_call: an exec() drain
        //  attempt from the owner must revert BindingForbidsThis)
        console2.log("=== loan 2 left LIVE: Drawn, bound, self-repaying ===");
        console2.log("CSM claimExecutors[0]:", IClaimSetupManager(CSM).claimExecutors(address(account))[0]);
        console2.log("CSM allowedRecipients[0]:", IClaimSetupManager(CSM).allowedClaimRecipients(address(account))[0]);
    }
}
