// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../src/YibbleUSD.sol";
import "../src/YipUSD.sol";
import "../src/YibbleSwap.sol";
import "../src/YibbleVault.sol";

contract YibbleV2Test is Test {
    YibbleUSD ybUSD;
    YipUSD ypUSD;
    YibbleSwap swap;
    YibbleVault vault;
    address owner = address(0xCEO);

    function setUp() public {
        vm.startPrank(owner);
        ybUSD = new YibbleUSD();
        ypUSD = new YipUSD();
        swap = new YibbleSwap(address(ypUSD), address(ybUSD));
        vault = new YibbleVault(IERC20(address(ybUSD)));

        // Seed swap with 1M ybUSD liquidity
        ybUSD.mint(address(swap), 1_000_000 * 10**6);
        vm.stopPrank();
    }

    function test_Swap_Fee() public {
        address user = address(0xUSER);
        vm.startPrank(owner);
        ypUSD.mint(user, 10_000 * 10**6);
        vm.stopPrank();

        vm.startPrank(user);
        ypUSD.approve(address(swap), 10_000 * 10**6);
        swap.swap(10_000 * 10**6);
        // 0.10% fee means 10,000 * 0.999 = 9,990 ybUSD
        assertEq(ybUSD.balanceOf(user), 9_990 * 10**6);
        vm.stopPrank();
    }

    function test_Vault_FeeAccrual() public {
        address user = address(0xUSER);
        vm.startPrank(owner);
        ybUSD.mint(user, 100_000 * 10**6);
        vm.stopPrank();

        vm.startPrank(user);
        ybUSD.approve(address(vault), 100_000 * 10**6);
        vault.deposit(100_000 * 10**6, user);
        vm.stopPrank();

        // Advance time by 1 year
        vm.warp(block.timestamp + 365 days);
        
        uint256 assetsBefore = vault.totalAssets();
        
        vm.prank(owner);
        vault.chargeManagementFee();
        
        uint256 assetsAfter = vault.totalAssets();
        
        // Fee should be ~0.20% of 100k = 200 ybUSD
        assertEq(assetsBefore - assetsAfter, 200 * 10**6);
    }
}
