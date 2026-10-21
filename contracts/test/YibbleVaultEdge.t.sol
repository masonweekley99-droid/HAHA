// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract MockUSDCEdge is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract YibbleVaultEdgeTest is Test {
    MockUSDCEdge usdc;
    YibbleVault  vault;
    address treasury = address(0xA11CE);
    address alice    = address(0xB0B);
    address bob      = address(0xCAFE);

    event FeeAccrued(uint256 amount, uint256 timestamp);
    event TreasuryUpdated(address indexed prev, address indexed next);

    function setUp() public {
        usdc  = new MockUSDCEdge();
        vault = new YibbleVault(usdc, treasury, address(this));
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob,   1_000_000e6);
    }

    // ---------------- accrueFee edge cases ----------------

    function testAccrueFeeNoOpWhenZeroElapsed() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(treasury);
        assertEq(vault.pendingFee(), 0, "no time elapsed -> zero fee");
        vault.accrueFee();
        assertEq(usdc.balanceOf(treasury), before, "no transfer");
    }

    function testAccrueFeeTwiceDoesNotDoubleFee() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        uint256 before = usdc.balanceOf(treasury);
        vault.accrueFee();
        uint256 afterFirst = usdc.balanceOf(treasury) - before;
        assertEq(afterFirst, 200e6, "first call = 0.20% of 100k");

        // immediately again: no time has passed since lastAccrual update
        vault.accrueFee();
        uint256 afterSecond = usdc.balanceOf(treasury) - before - afterFirst;
        assertEq(afterSecond, 0, "no double-charge");
    }

    function testAccrueFeeEmitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 365 days);
        uint256 expected = vault.pendingFee();
        vm.expectEmit(true, true, true, true, address(vault));
        emit FeeAccrued(expected, t0 + 365 days);
        vault.accrueFee();
    }

    function testAccrueFeeWhenFeeExceedsAssets() public {
        // 1000 years at 0.20% -> pendingFee = 2x totalAssets -> guard must trip
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1000 * 365 days);
        uint256 pending = vault.pendingFee();
        assertGt(pending, vault.totalAssets(), "fee > assets precondition");

        uint256 before = usdc.balanceOf(treasury);
        vault.accrueFee();
        assertEq(usdc.balanceOf(treasury), before, "guard blocked transfer");
        // lastAccrual still advances, so we don't accrue the pathological amount later
        assertEq(vault.lastAccrual(), block.timestamp);
    }

    function testAccrueFeeWithZeroDeposits() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.pendingFee(), 0);
        vault.accrueFee(); // must not revert, must not transfer
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function testPendingFeeMatchesActualTransfer() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 73 days); // arbitrary fractional-year
        uint256 viewFee   = vault.pendingFee();
        uint256 before    = usdc.balanceOf(treasury);
        vault.accrueFee();
        uint256 actualFee = usdc.balanceOf(treasury) - before;
        assertEq(actualFee, viewFee, "view == transfer");
    }

    function testAccrueFeeReducesSharePrice() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        uint256 priceBefore = vault.convertToAssets(1e6);
        vm.warp(block.timestamp + 365 days);
        vault.accrueFee();
        uint256 priceAfter = vault.convertToAssets(1e6);

        assertLt(priceAfter, priceBefore, "fees reduce NAV per share");
        // 0.20% of 1e6 share slice = 2000 -> 1e6 - 2000 = 998,000
        assertEq(priceAfter, 998_000, "1 share = 0.998 asset after 0.20% fee");
    }

    // ---------------- treasury ----------------

    function testSetTreasuryEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit TreasuryUpdated(treasury, bob);
        vault.setTreasury(bob);
        assertEq(vault.treasury(), bob);
    }

    function testSetTreasuryZeroReverts() public {
        vm.expectRevert(bytes("treasury=0"));
        vault.setTreasury(address(0));
    }

    // ---------------- ERC4626 edge cases ----------------

    function testDepositZeroReturnsZeroShares() public {
        // OZ v5 ERC4626 allows deposit(0): no revert, returns 0 shares.
        // Asserting the actual behavior so any future OZ upgrade that
        // changes this contract-visible behavior is caught here.
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        uint256 shares = vault.deposit(0, alice);
        assertEq(shares, 0, "zero deposit -> zero shares");
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        vm.stopPrank();
    }

    function testRedeemMoreThanBalanceReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        uint256 shares = vault.deposit(100_000e6, alice);
        vm.expectRevert();
        vault.redeem(shares + 1, alice, alice);
        vm.stopPrank();
    }

    function testMultipleDepositorsProRata() public {
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.prank(bob);
        usdc.approve(address(vault), 50_000e6);
        vm.prank(bob);
        uint256 bobShares = vault.deposit(50_000e6, bob);

        assertEq(bobShares, 50_000e6, "1:1 at same NAV");
        assertEq(vault.totalAssets(), 150_000e6);
        assertEq(vault.totalSupply(), 150_000e6);
    }

    function testDonationIncreasesSharePrice() public {
        // Direct USDC transfer to vault increases totalAssets without minting
        // shares. Expected OZ behavior; NOT a bug (OZ v5 mitigates inflation
        // attack via virtual offset). Documented via assertion.
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        uint256 priceBefore = vault.convertToAssets(1e6);
        vm.prank(bob);
        usdc.transfer(address(vault), 10_000e6); // donation
        uint256 priceAfter  = vault.convertToAssets(1e6);

        assertGt(priceAfter, priceBefore, "donation lifts NAV");
        assertEq(vault.totalAssets(), 110_000e6);
        assertEq(vault.totalSupply(), 100_000e6);
    }

    // ---------------- fuzz invariants ----------------

    function testFuzzAccrueFeeNeverExceedsAssets(uint64 elapsed) public {
        elapsed = uint64(bound(elapsed, 0, 2000 * 365 days));
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        vm.warp(block.timestamp + elapsed);
        uint256 before = usdc.balanceOf(treasury);
        vault.accrueFee();
        uint256 gained = usdc.balanceOf(treasury) - before;

        assertLe(gained, 100_000e6, "fee transfer never exceeds AUM");
        assertLe(vault.totalAssets(), 100_000e6);
    }

    function testFuzzFeeAccrualMonotonic(uint32 e1, uint32 e2) public {
        e1 = uint32(bound(e1, 1, 30 * 365 days));
        e2 = uint32(bound(e2, e1 + 1, 60 * 365 days));

        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + e1);
        uint256 p1 = vault.pendingFee();
        vm.warp(t0 + e2);
        uint256 p2 = vault.pendingFee();
        assertGe(p2, p1, "pendingFee non-decreasing in time");
    }
}
