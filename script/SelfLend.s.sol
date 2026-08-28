// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {RewardCollector} from "../src/RewardCollector.sol";
import {PassLedgerOracle, IFlareContractRegistry} from "../src/PassLedgerOracle.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IWNat} from "../src/interfaces/IWNat.sol";
import {IFtsoV2} from "../src/interfaces/IFtsoV2.sol";
import {IPChainStakeMirror} from "../src/interfaces/IPChainStakeMirror.sol";

interface IFlareSystemsManager {
    function getCurrentRewardEpochId() external view returns (uint24);
}

/// Self-lending walkthrough on Coston2: ONE wallet plays both lender and
/// borrower (the vault allows it — different role checks, same address), so
/// you can drive a whole loan yourself and watch every step. Deploys a fresh
/// v4 vault carrying ALL security fixes. TESTNET ONLY — testnet USDT0 from the
/// faucet, no real value.
///
/// Prereqs in the wallet (SELF_PK): testnet USDT0 (faucet "Request USDT0") to
/// lend, and C2FLR (faucet "Request C2FLR") for margin + gas.
///
/// Run:
///   SELF_PK=0x<your-testnet-key> forge script script/SelfLend.s.sol \
///     --rpc-url coston2 --broadcast --gas-estimate-multiplier 300 --slow
contract SelfLend is Script {
    address constant WNAT = 0xC67DCE33D7A8efA5FfEB961899C73fe01bCe9273;
    address constant USDT0 = 0xC1A5B41512496B80903D1f32d6dEa3a73212E71F; // 6dp
    address constant CSM = 0x5Ddb590530EF66775E6225671eaBD94959e9AE0e;
    address constant FTSOV2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    address constant FSM = 0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52;
    address constant REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;
    bytes21 constant FLR_USD = bytes21(0x01464c522f55534400000000000000000000000000);

    function run() external {
        uint256 pk = vm.envUint("SELF_PK");
        address me = vm.addr(pk);
        IWNat wnat = IWNat(WNAT);

        // Loan size — override with env vars. Faucet-friendly defaults: borrow
        // $0.30 (fixed-dollar), 100 FLR margin (a $0.30 debt needs margin worth
        // ~$0.60 at the ~$0.0065 testnet price -> ~92 FLR; 100 gives headroom),
        // 4-epoch term. Scale up with env vars once you've seen it work.
        uint256 principalUsd = vm.envOr("PRINCIPAL_USD", uint256(3e5)); // $0.30
        uint256 debtUsd = vm.envOr("DEBT_USD", uint256(3e5));
        uint256 marginFlr = vm.envOr("MARGIN_FLR", uint256(100 ether));

        uint64 epoch = uint64(IFlareSystemsManager(FSM).getCurrentRewardEpochId());

        vm.startBroadcast(pk);
        // 1. deploy v4 (all fixes) — you are the oracle poster / keeper too
        PassLedgerOracle oracle = new PassLedgerOracle(me, IFlareContractRegistry(REGISTRY), 8);
        LoanVault vault = new LoanVault(
            LoanVault.Config({
                usd: IERC20(USDT0),
                wnat: wnat,
                oracle: oracle,
                claimSetupManager: CSM,
                keeperExecutor: me,
                epochDurationSeconds: 21_600,
                ftso: IFtsoV2(FTSOV2),
                pchainMirror: IPChainStakeMirror(0xd2a1Bb23eB350814a30Dd6f9de78Bb2C8fdD9F1D),
                flrUsdFeedId: FLR_USD,
                maxPriceDeviationBps: 0, // self-loan: skip the pair band
                minSettledEpochs: 10,
                deadEpochsToTrigger: 4,
                gracePeriod: 7 days,
                maxPriceAge: 1 hours,
                requireProvenTrailing: false
            })
        );
        console2.log("v4 vault:", address(vault));
        console2.log("v4 oracle:", address(oracle));

        // 2. post your own ledger row so the loan underwrites (trailing 100 FLR,
        //    3 passes, 20 settled epochs, alive)
        oracle.post(me, epoch, 100 ether, 3, 20, true);

        // 3. lender leg: approve + offer (fixed-dollar) to yourself
        IERC20(USDT0).approve(address(vault), type(uint256).max);
        uint256 id = vault.offer(me, true, principalUsd, debtUsd, marginFlr, debtUsd / 10, 500, 4);
        console2.log("loan offered, id:", id);

        // 4. borrower leg: accept, wrap margin + a repayment buffer, approve
        vault.accept(id);
        wnat.deposit{value: marginFlr + 20 ether}(); // margin + repay buffer
        wnat.approve(address(vault), type(uint256).max);

        // 5. fund (lender) + margin + draw (borrower) — all you
        vault.fund(id);
        vault.postMargin(id);
        vault.draw(id);
        console2.log("DRAWN. your USDT0 balance now:", IERC20(USDT0).balanceOf(me));
        console2.log("outstanding (USD 6dp):", vault.getLoan(id).outstanding);

        // 6. repay in FLR valued at the live FtsoV2 price; excess over the
        //    debt returns to you as change
        vault.repay(id, 20 ether);
        console2.log("after one repayment, outstanding (USD 6dp):", vault.getLoan(id).outstanding);
        console2.log("loan status (3=Drawn,6=Repaid):", vault.statusOf(id));
        vm.stopBroadcast();

        console2.log("=== self-lending loan is LIVE on Coston2 ===");
        console2.log("watch it in the app (point app/app.js A.vault at the address above),");
        console2.log("or repay the rest:  cast send", address(vault));
        console2.log("   'repay(uint256,uint256)' <id> <flrWeiAmount> --private-key $SELF_PK ...");
    }
}
