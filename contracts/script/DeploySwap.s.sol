// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YipUSD} from "../src/YipUSD.sol";
import {YibbleUSD} from "../src/YibbleUSD.sol";
import {YibbleSwap} from "../src/YibbleSwap.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeploySwap is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Read existing vault USD address from env or use env-provided
        address ybUSDAddr = vm.envAddress("YBUSD_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        vm.startBroadcast(deployerKey);

        // Deploy ypUSD token
        YipUSD ypUSD = new YipUSD(deployer);
        console.log("YipUSD deployed:", address(ypUSD));

        // Deploy swap with 0.10% fee, treasury = deployer
        YibbleSwap swap = new YibbleSwap(
            IERC20(address(ypUSD)),
            IERC20(ybUSDAddr),
            deployer,       // treasury receives ypUSD
            10,             // 0.10% fee
            deployer
        );
        console.log("YibbleSwap deployed:", address(swap));

        // Fund swap reserve with 100,000 ybUSD (deployer must own these)
        IERC20 ybUSD = IERC20(ybUSDAddr);
        uint256 reserve = 100_000e6;
        require(ybUSD.balanceOf(deployer) >= reserve, "deployer needs 100k ybUSD");
        ybUSD.approve(address(swap), reserve);
        swap.fundReserve(reserve);
        console.log("Reserve funded:", reserve);

        // Mint 1,000,000 ypUSD to deployer for distribution
        ypUSD.mint(deployer, 1_000_000e6);
        console.log("Deployer ypUSD:", ypUSD.balanceOf(deployer));

        vm.stopBroadcast();

        console.log("");
        console.log("== wiring ==");
        console.log("Vault   :", vaultAddr);
        console.log("ybUSD   :", ybUSDAddr);
        console.log("ypUSD   :", address(ypUSD));
        console.log("Swap    :", address(swap));
    }
}
