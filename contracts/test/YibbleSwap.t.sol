// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YipUSD} from "../src/YipUSD.sol";
import {YibbleUSD} from "../src/YibbleUSD.sol";
import {YibbleSwap} from "../src/YibbleSwap.sol";

contract YibbleSwapTest is Test {
    YipUSD     ypUSD;
    YibbleUSD  ybUSD;
    YibbleSwap swap;

    address treasury = address(0xA11CE);
    address alice    = address(0xB0B);
    address bob      = address(0xCAFE);

    function setUp() public {
        ypUSD = new YipUSD(address(this));
        ybUSD = new YibbleUSD(address(this));
        swap  = new YibbleSwap(
            IERC20(address(ypUSD)),
            IERC20(address(ybUSD)),
            treasury,
            10,           // 0.10% fee
            address(this)
        );

        // Fund the swap's ybUSD reserve with 1,000,000 ybUSD
        ybUSD.mint(address(this), 1_000_000e6);
        ybUSD.approve(address(swap), type(uint256).max);
        swap.fundReserve(1_000_000e6);

        // Give alice and bob some ypUSD
        ypUSD.mint(alice, 10_000e6);
        ypUSD.mint(bob,   10_000e6);
    }

    // ---------- state ----------

    function testInitialState() public view {
        assertEq(address(swap.ypUSD()), address(ypUSD));
        assertEq(address(swap.ybUSD()), address(ybUSD));
        assertEq(swap.treasury(), treasury);
        assertEq(swap.feeBps(), 10);
        assertEq(swap.reserve(), 1_000_000e6);
    }

    function testQuote() public view {
        (uint256 out, uint256 fee) = swap.quote(1_000e6);
        assertEq(fee, 1e6);      // 0.10% of 1000 = 1
        assertEq(out, 999e6);    // 1000 - 1 = 999
    }

    // ---------- swap ----------

    function testSwapPullsYpSendsYb() public {
        vm.startPrank(alice);
        ypUSD.approve(address(swap), 1_000e6);
        uint256 ybOut = swap.swapYpForYb(1_000e6, 0);
        vm.stopPrank();

        assertEq(ybOut, 999e6, "0.10% fee taken");
        assertEq(ybUSD.balanceOf(alice), 999e6, "alice received ybUSD");
        assertEq(ypUSD.balanceOf(treasury), 1_000e6, "ypUSD went to treasury");
        assertEq(ypUSD.balanceOf(alice), 9_000e6, "alice ypUSD reduced");
        assertEq(swap.reserve(), 1_000_000e6 - 999e6, "reserve reduced");
    }

    function testSwapEmitsEvent() public {
        vm.startPrank(alice);
        ypUSD.approve(address(swap), 1_000e6);
        vm.expectEmit(true, false, false, true, address(swap));
        emit YibbleSwap.Swapped(alice, 1_000e6, 999e6, 1e6);
        swap.swapYpForYb(1_000e6, 0);
        vm.stopPrank();
    }

    function testSwapRevertsOnZero() public {
        vm.startPrank(alice);
        ypUSD.approve(address(swap), 1);
        vm.expectRevert(YibbleSwap.ZeroAmount.selector);
        swap.swapYpForYb(0, 0);
        vm.stopPrank();
    }

    function testSwapRevertsOnSlippage() public {
        vm.startPrank(alice);
        ypUSD.approve(address(swap), 1_000e6);
        vm.expectRevert(bytes("slippage"));
        swap.swapYpForYb(1_000e6, 1_000e6); // expects full 1000 out, only 999 available
        vm.stopPrank();
    }

    function testSwapRevertsIfReserveTooLow() public {
        // Drain the reserve first
        swap.withdrawReserve(swap.reserve() - 100e6, address(this));

        vm.startPrank(alice);
        ypUSD.approve(address(swap), 1_000e6);
        vm.expectRevert(); // insufficient reserve
        swap.swapYpForYb(1_000e6, 0);
        vm.stopPrank();
    }

    // ---------- owner controls ----------

    function testSetFeeBps() public {
        swap.setFeeBps(25);
        assertEq(swap.feeBps(), 25);
        (uint256 out, uint256 fee) = swap.quote(1_000e6);
        assertEq(fee, 2.5e6);
        assertEq(out, 997.5e6);
    }

    function testSetFeeBpsRejectsHigh() public {
        vm.expectRevert();
        swap.setFeeBps(101);
    }

    function testFundReserve() public {
        uint256 before = swap.reserve();
        ybUSD.mint(address(this), 500e6);
        ybUSD.approve(address(swap), type(uint256).max);
        swap.fundReserve(500e6);
        assertEq(swap.reserve(), before + 500e6);
    }

    function testWithdrawReserveOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        swap.withdrawReserve(100e6, alice);

        swap.withdrawReserve(100e6, address(this));
        assertEq(swap.reserve(), 1_000_000e6 - 100e6);
    }

    function testSetTreasury() public {
        swap.setTreasury(bob);
        assertEq(swap.treasury(), bob);
    }

    function testSetTreasuryZeroReverts() public {
        vm.expectRevert(bytes("treasury=0"));
        swap.setTreasury(address(0));
    }

    // ---------- fuzz ----------

    function testFuzzSwap(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 10_000e6)); // 1 to 10k ypUSD

        vm.startPrank(alice);
        ypUSD.approve(address(swap), amount);
        uint256 out = swap.swapYpForYb(amount, 0);
        vm.stopPrank();

        uint256 expectedFee = (uint256(amount) * 10) / 10_000;
        assertEq(out, uint256(amount) - expectedFee, "out = amount - 0.10%");
        assertEq(ybUSD.balanceOf(alice), out);
    }

    function testFuzzQuoteMatchesSwap(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 10_000e6));
        (uint256 quoted, ) = swap.quote(amount);

        vm.startPrank(alice);
        ypUSD.approve(address(swap), amount);
        uint256 actual = swap.swapYpForYb(amount, 0);
        vm.stopPrank();

        assertEq(actual, quoted, "quote == actual");
    }
}
