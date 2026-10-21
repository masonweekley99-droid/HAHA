#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Fix 2 edge tests - both were MY test bugs, not contract bugs
#  1. price math: 0.20% of 1e6 = 2000 (not 200) -> 998,000
#  2. OZ v5 ERC4626 allows deposit(0) without revert
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

# ---------- 1. patch the two failing tests via python (anchor-safe) ----------
info "patching testAccrueFeeReducesSharePrice + testDepositZeroReverts"
python3 - <<'PY_EOF'
import pathlib, sys
p = pathlib.Path("test/YibbleVaultEdge.t.sol")
src = p.read_text()

# --- Fix 1: price math ---
old1 = '''        assertLt(priceAfter, priceBefore, "fees reduce NAV per share");
        assertApproxEqAbs(priceAfter, 999_800, 100, "~0.20% lower");'''
new1 = '''        assertLt(priceAfter, priceBefore, "fees reduce NAV per share");
        // 0.20% of 1e6 share slice = 2000 -> 1e6 - 2000 = 998,000
        assertEq(priceAfter, 998_000, "1 share = 0.998 asset after 0.20% fee");'''
if old1 not in src:
    sys.exit("anchor 1 not found")
src = src.replace(old1, new1)

# --- Fix 2: deposit(0) does not revert in OZ v5 ERC4626 ---
old2 = '''    function testDepositZeroReverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert();
        vault.deposit(0, alice);
        vm.stopPrank();
    }'''
new2 = '''    function testDepositZeroReturnsZeroShares() public {
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
    }'''
if old2 not in src:
    sys.exit("anchor 2 not found")
src = src.replace(old2, new2)

p.write_text(src)
print("patched:", p)
PY_EOF
ok "edge tests patched"

# ---------- 2. rerun full suite ----------
info "forge test -vv"
if ! forge test -vv; then
  die "still failing - see above"
fi
ok "all tests passed"

# ---------- 3. coverage ----------
info "forge coverage --report summary"
forge coverage --report summary 2>/dev/null || warn "coverage binary unavailable"

# ---------- 4. summary ----------
cat <<SUMMARY_EOF

================================================================
  YIBBLE VAULT - EDGE TESTS GREEN
================================================================
  Test suites:
    test/YibbleVault.t.sol      -> 8 tests (core)
    test/YibbleVaultEdge.t.sol  -> 15 tests (edge + fuzz)

  Two test bugs fixed (contract unchanged):
    1. testAccrueFeeReducesSharePrice
         was: assertApproxEqAbs(priceAfter, 999_800, 100)
         now: assertEq(priceAfter, 998_000)
         reason: 0.20% of 1e6 = 2000, not 200.
                 Correct post-fee price of 1e6-share slice is 998,000.

    2. testDepositZeroReverts -> renamed testDepositZeroReturnsZeroShares
         was: vm.expectRevert() on vault.deposit(0, alice)
         now: assertEq(shares, 0)
         reason: OZ v5 ERC4626 does NOT revert on zero deposit.
                 It returns 0 shares and emits Deposit(assets=0,shares=0).
                 Asserting the actual behavior locks it in against
                 future OZ upgrades that might change it.

  Key lesson: when a test fails, FIRST ask "is the contract wrong or is
  my test wrong?" Here, the contract was right on both counts. The
  discipline is: never change the contract to make a test pass until
  you're certain the test's expectation is actually what you want.

  Contract state: unchanged since last green build.
    src/YibbleVault.sol has 0 changes this round.

  Next real step (fork test against real USDC):
    forge test --fork-url \$TESTNET_RPC \\
        --match-contract YibbleVaultForkTest -vvv
    Requires a fork test file. Want me to write one? It would:
      - fork Sepolia or Base Sepolia
      - use real Circle USDC address
      - deposit 1000 USDC via a whale-impersonated account
      - verify redeem + fee accrual against live token
      - catch anything MockUSDC hides (pausable, blocklist, decimals)
================================================================
SUMMARY_EOF

ok "done"
