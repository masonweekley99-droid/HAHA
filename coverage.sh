#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  YIBBLE VAULT - Edge-case tests + coverage report
#  Fills gaps: accrueFee guard, donation, event assertions,
#  multi-depositor pro-rata, pendingFee==actual invariant.
# ============================================================
set -uo pipefail

GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

PROJECT="$HOME/yibble/contracts"
cd "$PROJECT" || die "cd $PROJECT failed"
info "project: $PROJECT"

# ---------- 1. edge test file ----------
info "writing test/YibbleVaultEdge.t.sol (branch coverage + invariants)"
cat > test/YibbleVaultEdge.t.sol <<'TEST_EOF'
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

        vm.warp(block.timestamp + 365 days);
        uint256 expected = vault.pendingFee();
        vm.expectEmit(true, true, true, true, address(vault));
        emit FeeAccrued(expected, block.timestamp);
        vault.accrueFee();
    }

    function testAccrueFeeWhenFeeExceedsAssets() public {
        // 1000 years at 0.20% -> pendingFee = 2x totalAssets -> guard must trip
        vm.startPrank(alice);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000 * 365 days);
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
        assertApproxEqAbs(priceAfter, 999_800, 100, "~0.20% lower");
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

    function testDepositZeroReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert();
        vault.deposit(0, alice);
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

        vm.warp(block.timestamp + e1);
        uint256 p1 = vault.pendingFee();
        vm.warp(block.timestamp + (e2 - e1));
        uint256 p2 = vault.pendingFee();
        assertGe(p2, p1, "pendingFee non-decreasing in time");
    }
}
TEST_EOF
ok "edge test file written"

# ---------- 2. run all tests ----------
info "forge test -vvv (all suites)"
forge test -vvv || die "tests failed"
ok "all tests passed"

# ---------- 3. coverage summary ----------
info "forge coverage --report summary"
if forge coverage --report summary 2>/dev/null; then
  ok "coverage report generated"
else
  warn "coverage not available - falling back to per-file test list"
  forge test --list || true
fi

# ---------- 4. ABI dump for integrators ----------
info "ABI -> out/YibbleVault.abi.json"
forge inspect YibbleVault abi > out/YibbleVault.abi.json 2>/dev/null \
  && ok "ABI written ($(wc -c < out/YibbleVault.abi.json) bytes)" \
  || warn "ABI inspect skipped"

# ---------- 5. summary ----------
cat <<SUMMARY_EOF

================================================================
  YIBBLE VAULT - COVERAGE PASS COMPLETE
================================================================
  Suite 1: test/YibbleVault.t.sol        (8 core tests)
  Suite 2: test/YibbleVaultEdge.t.sol    (15 edge + invariant tests)

  New coverage this round:
    - accrueFee guard: fee > totalAssets() blocked, lastAccrual still advances
    - accrueFee double-call: no double-charge within a block
    - pendingFee() == actual transfer (view/effect parity)
    - FeeAccrued event emitted with exact args
    - TreasuryUpdated event emitted
    - setTreasury(address(0)) reverts with "treasury=0"
    - deposit(0) reverts (OZ ERC4626 zero-share guard)
    - redeem(shares+1) reverts (OZ ERC4626 insufficient balance)
    - multi-depositor pro-rata (alice 100k + bob 50k -> exact shares)
    - donation attack documented (NAV lift, OZ v5 virtual offset mitigates)
    - fuzz: fee transfer never exceeds AUM, pendingFee monotonic in time

  What to look at in coverage output:
    src/YibbleVault.sol      target: 100% lines, 100% branches
    - If any line in accrueFee() is uncovered, tell me which and I'll
      add the specific test that hits it.
    - OZ libs will show partial coverage; that's normal (they are
      audited upstream; we don't re-test them).

  Known limitation of THIS design (not a bug, a design choice):
    accrueFee() is externally callable and pokes lastAccrual. If no
    keeper calls it, fees silently don't accrue. Options:
      1. Add a keeper (Chainlink Automation / Gelato) - recommended
      2. Override _deposit/_withdraw to accrue inline - changes fairness
         (charges new depositor for old elapsed time)
      3. Leave as-is, rely on UX to call it before redeem
    For v0.1 leave as-is + add keeper before mainnet.

  Next steps:
    forge test --match-contract YibbleVaultEdgeTest -vvv
    forge coverage --report lcov && genhtml lcov.info -o coverage/
    forge snapshot                       # gas snapshot for CI
    forge doc                            # generate docs from natspec

  Mainnet gate (unchanged):
    [ ] Treasury = Safe multisig
    [ ] Owner    = Safe multisig
    [ ] ASSET    = real USDC address on target chain
    [ ] Keeper for accrueFee()
    [ ] External audit
    [ ] Timelock on setTreasury (consider adding)
================================================================
SUMMARY_EOF

ok "done"
