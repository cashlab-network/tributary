// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";

interface IFlareSystemsManager {
    function getCurrentRewardEpochId() external view returns (uint24);
}

/// v3 on the REAL Coston2: both of today's fixes live (chain-read epoch
/// duration; escrow claim enrollment), per-chain policy, the price band, and
/// the FIRST fixed-dollar loan — repaid in FLR valued by the REAL FtsoV2,
/// with the ledger posted under the REAL current reward epoch id.
/// Run: source .env, then
///   forge script script/V3.s.sol --rpc-url coston2 --broadcast \
///     --gas-estimate-multiplier 300 --slow
contract V3 is Script {
    address constant WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;
    address constant USDT0 = 0xC1A5B41512496B80903D1f32d6dEa3a73212E71F; // 6dp
    address constant CSM = 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e;
    address constant FTSOV2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    address constant FSM = 0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52;
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);

    // Faucet-scale fixed-dollar terms: owe $0.05, margin 16 FLR (~2x at
    // testnet prices), trailing 4 FLR/epoch, 4-epoch term.
    uint256 constant PRINCIPAL_USD = 50_000; // $0.05 advanced
    uint256 constant DEBT_USD = 50_000; // $0.05 owed
    uint256 constant MARGIN = 16 ether;
    uint256 constant DEFAULT_FEE_USD = 5_000; // $0.005
    uint256 constant BENCHMARK_BPS = 500;
    uint16 constant TERM_EPOCHS = 4;
    uint192 constant TRAILING = 4 ether;
    uint256 constant EPOCH_REWARD = 4 ether;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        uint256 borrowerPk = vm.envUint("BORROWER_PK");
        address deployer = vm.addr(deployerPk);
        address borrower = vm.addr(borrowerPk);
        IWNat wnat = IWNat(WNAT);

        // the REAL current reward epoch id (G3: no invented epochs)
        uint64 epoch = uint64(IFlareSystemsManager(FSM).getCurrentRewardEpochId());
        console2.log("real Coston2 reward epoch:", epoch);

        vm.startBroadcast(deployerPk);
        PassLedgerOracle oracle =
            new PassLedgerOracle(deployer, IFlareContractRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019));
        LoanVault vault = new LoanVault(
            LoanVault.Config({
                usd: IERC20(USDT0),
                wnat: wnat,
                oracle: oracle,
                claimSetupManager: CSM,
                keeperExecutor: deployer,
                epochDurationSeconds: 21_600, // chain fact, verified via FSM
                ftso: IFtsoV2(FTSOV2),
                flrUsdFeedId: FLR_USD,
                maxPriceDeviationBps: 2_500, // ±25% pair sanity band
                minSettledEpochs: 10,
                deadEpochsToTrigger: 4,
                gracePeriod: 7 days,
                maxPriceAge: 1 hours
            })
        );
        oracle.post(borrower, epoch, TRAILING, 3, 20, true);
        IERC20(USDT0).approve(address(vault), type(uint256).max);
        uint256 id = vault.offer(
            borrower, true, PRINCIPAL_USD, DEBT_USD, MARGIN, DEFAULT_FEE_USD, BENCHMARK_BPS, TERM_EPOCHS
        );
        payable(borrower).transfer(30 ether); // margin + stream + gas cushion
        vm.stopBroadcast();
        console2.log("v3 vault:", address(vault));
        console2.log("v3 oracle:", address(oracle));
        console2.log("fixed-dollar loan id:", id);

        vm.startBroadcast(borrowerPk);
        vault.accept(id); // dual cap valued at the REAL FtsoV2 price
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
        console2.log("drawn; borrower USDT0:", IERC20(USDT0).balanceOf(borrower));

        RewardCollector collector = vault.getLoan(id).collector;
        console2.log("collector:", address(collector));
        for (uint256 i = 1; i <= 3; i++) {
            vm.startBroadcast(borrowerPk);
            (bool ok,) = address(collector).call{value: EPOCH_REWARD}("");
            require(ok, "reward transfer failed");
            vm.stopBroadcast();

            vm.startBroadcast(deployerPk);
            collector.sweep(); // valued at the live FtsoV2 price
            vm.stopBroadcast();
            console2.log("sweep", i, "outstanding USD(6dp):", vault.getLoan(id).outstanding);
            if (vault.statusOf(id) == 6) break;
        }

        vm.startBroadcast(deployerPk);
        vault.withdraw(address(wnat));
        vm.stopBroadcast();
        vm.startBroadcast(borrowerPk);
        vault.withdraw(address(wnat));
        vm.stopBroadcast();

        console2.log("=== FINAL ===");
        console2.log("status (6 = Repaid):", vault.statusOf(id));
        console2.log("lender WFLR balance (incl. prior holdings):", wnat.balanceOf(deployer));
        console2.log("borrower USDT0 kept:", IERC20(USDT0).balanceOf(borrower));
    }
}
