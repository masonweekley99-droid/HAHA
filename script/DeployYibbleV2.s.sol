// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Script.sol";
import "../src/YibbleUSD.sol";
import "../src/YipUSD.sol";
import "../src/YibbleSwap.sol";
import "../src/YibbleVault.sol";

contract DeployYibbleV2 is Script {
    function run() external {
        vm.startBroadcast();
        
        YibbleUSD ybUSD = new YibbleUSD();
        YipUSD ypUSD = new YipUSD();
        YibbleSwap swap = new YibbleSwap(address(ypUSD), address(ybUSD));
        YibbleVault vault = new YibbleVault(IERC20(address(ybUSD)));

        // Seed Swap with 10M ybUSD
        ybUSD.mint(address(swap), 10_000_000 * 10**6);
        
        // Mint 1M ypUSD to the CEO for distribution
        ypUSD.mint(msg.sender, 1_000_000 * 10**6);

        vm.stopBroadcast();
        console.log("ADDR_YBUSD", address(ybUSD));
        console.log("ADDR_YPUSD", address(ypUSD));
        console.log("ADDR_SWAP", address(swap));
        console.log("ADDR_VAULT", address(vault));
    }
}
