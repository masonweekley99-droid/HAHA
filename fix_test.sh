#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Fix testOwnerZeroReverts: OZ v5 Ownable reverts first
#  with OwnableInvalidOwner(0x0) before our body runs.
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

# ---------- 1. drop the redundant owner=0 require in contract ----------
info "removing redundant owner=0 require (OZ Ownable already guards it)"
python3 - <<'PY_EOF'
import re, pathlib
p = pathlib.Path("src/YibbleVault.sol")
src = p.read_text()
# remove the require(initialOwner != address(0), "owner=0"); line
src = re.sub(
    r'[ \t]*require\(initialOwner\s*!=\s*address\(0\),\s*"owner=0"\);\s*\n',
    '',
    src
)
p.write_text(src)
print("patched:", p)
PY_EOF
ok "contract cleaned"

# ---------- 2. rewrite the failing test to expect OZ custom error ----------
info "patching testOwnerZeroReverts to expect OwnableInvalidOwner"
python3 - <<'PY_EOF'
import pathlib
p = pathlib.Path("test/YibbleVault.t.sol")
src = p.read_text()

old = '''    function testOwnerZeroReverts() public {
        vm.expectRevert(bytes("owner=0"));
        new YibbleVault(usdc, treasury, address(0));
    }'''

new = '''    function testOwnerZeroReverts() public {
        // OZ v5 Ownable reverts inside its own constructor with a custom
        // error before our body executes, so we expect that, not "owner=0".
        vm.expectRevert(
            abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0))
        );
        new YibbleVault(usdc, treasury, address(0));
    }'''

if old not in src:
    raise SystemExit("anchor not found - aborting to avoid corrupting test")
p.write_text(src.replace(old, new))
print("patched:", p)
PY_EOF
ok "test patched"

# ---------- 3. optional: remove forge-init Counter noise ----------
if [ -f test/Counter.t.sol ] || [ -f src/Counter.sol ]; then
  info "removing forge-init Counter boilerplate (not part of project)"
  rm -f test/Counter.t.sol src/Counter.sol script/Counter.s.sol 2>/dev/null || true
  ok "Counter files removed"
fi

# ---------- 4. rebuild + retest ----------
info "forge build"
forge build || die "build failed"
ok "build passed"

info "forge test -vv"
if ! forge test -vv; then
  die "tests still failing - see above"
fi
ok "all tests passed"

# ---------- 5. summary ----------
cat <<SUMMARY_EOF

================================================================
  YIBBLE VAULT - ALL TESTS GREEN
================================================================
  Contract : src/YibbleVault.sol
  Tests    : test/YibbleVault.t.sol
  Deploy   : script/Deploy.s.sol

  What changed this round:
    - Removed redundant require(initialOwner != address(0), "owner=0")
      because OZ v5 Ownable(initialOwner) already reverts with
      OwnableInvalidOwner(address) inside its own constructor.
    - testOwnerZeroReverts now asserts the OZ custom error via
      abi.encodeWithSignature("OwnableInvalidOwner(address)", 0x0).
    - Removed forge-init Counter.sol / Counter.t.sol boilerplate.

  Why this matters: expecting the *exact* revert selector (not just
  "any revert") is what a real auditor checks for - it proves your
  contract fails for the reason you think it does.

  Next:
    forge test -vvv
    forge coverage
    forge inspect YibbleVault abi

  Mainnet checklist unchanged:
    [ ] Treasury = Safe multisig
    [ ] Owner    = Safe multisig
    [ ] ASSET    = real USDC on target chain
    [ ] Keeper for accrueFee()
    [ ] Audit
================================================================
SUMMARY_EOF

ok "done"
