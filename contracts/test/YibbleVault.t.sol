// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract YibbleVaultTest is Test {
    MockUSDC usdc;
    YibbleVault vault;
    address treasury = address(0xA11CE);
    address alice    = address(0xB0B);
    address bob      = address(0xCAFE);

    function setUp() public {
        usdc  = new MockUSDC();
        vault = new YibbleVault(usdc, treasury, address(this));
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob,   1_000_000e6);
    }

    function testInitialState() public view {
        assertEq(vault.name(), "Yibble Stock");
        assertEq(vault.symbol(), "YIB");
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.owner(), address(this));
        assertEq(vault.totalAssets(), 0);
    }

    function testDepositRedeemRoundTrip() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        uint256 shares = vault.deposit(100_000e6, alice);
        assertEq(shares, 100_000e6);
        assertEq(vault.balanceOf(alice), shares);

        uint256 out = vault.redeem(shares, alice, alice);
        assertEq(out, 100_000e6);
        vm.stopPrank();
    }

    function testFeeAccrual() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(treasury);
        vm.warp(block.timestamp + 365 days);
        uint256 expected = vault.pendingFee();
        vault.accrueFee();
        uint256 gained = usdc.balanceOf(treasury) - before;

        assertApproxEqAbs(gained, expected, 1e6);
        assertEq(gained, 200e6); // 0.20% of 100k USDC
    }

    function testTreasuryZeroReverts() public {
        vm.expectRevert(bytes("treasury=0"));
        new YibbleVault(usdc, address(0), address(this));
    }

    function testOwnerZeroReverts() public {
        // OZ v5 Ownable reverts inside its own constructor with a custom
        // error before our body executes, so we expect that, not "owner=0".
        vm.expectRevert(
            abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0))
        );
        new YibbleVault(usdc, treasury, address(0));
    }

    function testOnlyOwnerSetTreasury() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setTreasury(alice);

        vault.setTreasury(bob);
        assertEq(vault.treasury(), bob);
    }

    function testOwnershipTwoStepTransfer() public {
        // Ownable2Step: transfer initiates, only completes on accept
        vault.transferOwnership(alice);
        assertEq(vault.owner(), address(this)); // not yet
        assertEq(vault.pendingOwner(), alice);

        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    function testFuzzDeposit(uint96 amount) public {
        amount = uint96(bound(amount, 1, 500_000e6));
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        uint256 round  = vault.redeem(shares, alice, alice);
        assertLe(round, amount);
        assertApproxEqAbs(round, amount, 1);
        vm.stopPrank();
    }
}
