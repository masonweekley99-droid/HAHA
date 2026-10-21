// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeployYibbleVault is Script {
    function run() external {
        address asset    = vm.envAddress("ASSET_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address owner    = vm.envOr("OWNER_ADDRESS", msg.sender);

        vm.startBroadcast();
        YibbleVault vault = new YibbleVault(IERC20(asset), treasury, owner);
        vm.stopBroadcast();

        console.log("YibbleVault   :", address(vault));
        console.log("asset         :", asset);
        console.log("treasury      :", treasury);
        console.log("owner         :", owner);
    }
}
