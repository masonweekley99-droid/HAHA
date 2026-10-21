// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleUSD} from "../src/YibbleUSD.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeployLocal is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        YibbleUSD usd = new YibbleUSD(deployer);
        YibbleVault vault = new YibbleVault(
            IERC20(address(usd)),
            deployer,   // treasury
            deployer    // owner
        );

        usd.mint(deployer, 1_000_000 * 10 ** 6);

        usd.approve(address(vault), 100_000 * 10 ** 6);
        vault.deposit(100_000 * 10 ** 6, deployer);

        vm.stopBroadcast();

        console.log("== deployment summary ==");
        console.log("Deployer    :", deployer);
        console.log("YibbleUSD   :", address(usd));
        console.log("YibbleVault :", address(vault));
        console.log("Vault assets:", vault.totalAssets());
        console.log("Vault shares:", vault.totalSupply());
    }
}
