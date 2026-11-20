// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {WarungPay} from "../src/WarungPay.sol";

/// @notice Deploy WarungPay to Aevum testnet (chain 44005).
/// @dev tUSD8 address is fixed for Aevum testnet. Private key comes from the
///      PRIVATE_KEY env var — never hardcode it. Run via deploy.sh, which
///      reads it from hidden_files/deployer.json without printing it.
///      Example: ./deploy.sh
///      (forge script script/Deploy.s.sol:Deploy --rpc-url $RPC --broadcast --verify
///       --verifier blockscout --verifier-url https://explorer-test.qday.info/api)
contract Deploy is Script {
    /// @notice tUSD8 on Aevum testnet (6 decimals).
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (WarungPay) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        WarungPay wp = new WarungPay(TUSD8);
        vm.stopBroadcast();
        console.log("WarungPay deployed at:", address(wp));
        console.log("token (tUSD8):", TUSD8);
        return wp;
    }
}
