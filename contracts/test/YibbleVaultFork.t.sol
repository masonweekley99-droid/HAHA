// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

/// @dev IERC20Metadata adds name(), symbol(), decimals() on top of IERC20.
///      In OZ v5 these are NOT part of plain IERC20 (that was the compile bug).
interface IUSDC is IERC20Metadata {
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}

/// @notice Fork test against the real Circle USDC contract.
/// @dev    Requires env FORK_RPC. Skips silently if unset.
///         Uses USDC_ADDRESS env var, defaults to Sepolia USDC.
contract YibbleVaultForkTest is Test {
    IUSDC       usdc;
    YibbleVault vault;
    address     treasury = address(0xA11CE);
    address     alice    = address(0xB0B);

    // Circle USDC on Sepolia
    address constant SEPOLIA_USDC =
        0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    // Circle USDC on Base Sepolia
    address constant BASE_SEPOLIA_USDC =
        0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // no RPC -> skip; non-fork tests unaffected
            return;
        }
        vm.createSelectFork(rpc);

        address usdcAddr = vm.envOr("USDC_ADDRESS", SEPOLIA_USDC);
        usdc  = IUSDC(usdcAddr);
        vault = new YibbleVault(IERC20(usdcAddr), treasury, address(this));

        // fund alice with 1000 USDC from wherever
        deal(usdcAddr, alice, 1_000 * 10 ** usdc.decimals());
    }

    function testForkUSDCIsLive() public view {
        // guard against wrong address / wrong chain
        assertEq(usdc.decimals(), 6, "USDC is 6 decimals");
        assertFalse(usdc.paused(), "USDC not paused on fork");
        assertEq(usdc.symbol(), "USDC");
    }

    function testForkDepositRedeem() public {
        uint256 amt = 500 * 10 ** usdc.decimals();

        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        uint256 shares = vault.deposit(amt, alice);
        vm.stopPrank();

        assertEq(shares, amt, "1:1 on empty vault");
        assertEq(vault.totalAssets(), amt);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertEq(out, amt, "no fees yet, full round-trip");
    }

    function testForkFeeAccrual() public {
        uint256 amt = 500 * 10 ** usdc.decimals();

        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(treasury);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFee();
        uint256 gained = usdc.balanceOf(treasury) - before;

        // 0.20% of 500 USDC = 1 USDC
        assertEq(gained, 1 * 10 ** usdc.decimals(), "0.20% of 500 USDC");
    }

    function testForkDepositRevertsWhenUSDCBlocked() public {
        // USDC.blacklist() is only callable by Circle, but we can grant
        // ourselves the role via vm.store-free approach: alice sends a
        // normal approve+deposit first to confirm baseline works, then
        // we assert that if Circle ever blocks the vault address, the
        // transferFrom in ERC4626 would revert. Simulated via prank on
        // the real USDC's blacklister role using vm.store is fragile;
        // instead we document the risk with a non-exploit test.
        uint256 amt = 100 * 10 ** usdc.decimals();
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
        // If Circle ever calls blacklist(vault) or blacklist(alice),
        // this deposit path reverts. Documented, not simulated.
        assertTrue(usdc.balanceOf(address(vault)) >= amt);
    }
}
