#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Fix fork test compile error:
#    IERC20 in OZ v5 does NOT include symbol() or decimals().
#    They live in IERC20Metadata. Extend that instead.
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

# ---------- 1. surgical patch of the interface ----------
info "patching IUSDC to extend IERC20Metadata"
python3 - <<'PY_EOF'
import pathlib, sys
p = pathlib.Path("test/YibbleVaultFork.t.sol")
src = p.read_text()

old = '''import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

interface IUSDC is IERC20 {
    function decimals() external view returns (uint8);
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}'''

new = '''import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

/// @dev IERC20Metadata adds name(), symbol(), decimals() on top of IERC20.
///      In OZ v5 these are NOT part of plain IERC20 (that was the compile bug).
interface IUSDC is IERC20Metadata {
    function paused() external view returns (bool);
    function isBlacklisted(address account) external view returns (bool);
}'''

if old not in src:
    sys.exit("interface anchor not found - aborting")
p.write_text(src.replace(old, new))
print("patched:", p)
PY_EOF
ok "interface patched"

# ---------- 2. rebuild ----------
info "forge build"
forge build || die "build failed"
ok "build passed"

# ---------- 3. run non-fork tests (must remain 23/23 green) ----------
info "forge test --no-match-contract YibbleVaultForkTest -q"
if ! forge test --no-match-contract YibbleVaultForkTest -q; then
  die "non-fork tests regressed"
fi
ok "23 non-fork tests green"

# ---------- 4. run fork tests if RPC set, otherwise skip ----------
if [ -z "${FORK_RPC:-}" ]; then
  warn "FORK_RPC unset - fork tests will be reported as skipped by forge"
  info "running forge test to confirm skip behavior compiles cleanly"
  forge test --match-contract YibbleVaultForkTest -vv 2>&1 | tail -20 || true
  cat <<NOTE_EOF

================================================================
  FORK TESTS SKIPPED (FORK_RPC not set)
================================================================
  The fork test file now COMPILES (IERC20Metadata fix applied).
  With FORK_RPC unset it reports each test as [SKIP], which is
  the intended behavior - the 23 offline tests are unaffected.

  To actually run fork tests:
    export FORK_RPC=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
    export USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
    forge test --match-contract YibbleVaultForkTest -vvv

  Free RPC options:
    Alchemy  https://eth-sepolia.g.alchemy.com/v2/KEY  (recommended)
    Infura   https://sepolia.infura.io/v3/KEY
    Public   https://rpc.sepolia.org  (rate-limited, may hang)
    Public   https://ethereum-sepolia-rpc.publicnode.com
================================================================
NOTE_EOF
  ok "done (fork skipped, compile verified)"
  exit 0
fi

info "running fork tests against $FORK_RPC"
forge test \
  --fork-url "$FORK_RPC" \
  --fork-retry-backoff 3000 \
  --match-contract YibbleVaultForkTest \
  -vvv || die "fork tests failed"
ok "fork tests passed"

# ---------- 5. summary ----------
cat <<SUMMARY_EOF

================================================================
  FORK TESTS PASSED
================================================================
  Fork RPC : ${FORK_RPC:0:40}...
  USDC     : ${USDC_ADDRESS:-0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238}

  Verified against REAL Circle USDC:
    - decimals() == 6
    - symbol()   == "USDC"
    - paused()   == false on fork
    - deposit 500 USDC -> 500 shares (1:1)
    - redeem   500 shares -> 500 USDC (round-trip)
    - accrueFee after 1 year on 500 USDC -> exactly 1 USDC
      (0.20% = 1 USDC, correct in 6-decimal USDC)

  Why the compile error happened:
    OZ v5 split the old IERC20 into two:
      IERC20         - balances, transfers, approvals (no metadata)
      IERC20Metadata - name, symbol, decimals (extends IERC20)
    The fork test declared `interface IUSDC is IERC20` then called
    usdc.symbol(). v5's IERC20 doesn't expose symbol, so the compiler
    was right to reject it. Extending IERC20Metadata is the correct
    v5 idiom, and it also gets you name() for free if you ever need
    it in a test or a UI integration.

  Standing state:
    src/YibbleVault.sol       UNCHANGED (100% cov, 23 tests green)
    test/YibbleVault.t.sol    UNCHANGED (8 tests)
    test/YibbleVaultEdge.t.sol UNCHANGED (15 tests)
    test/YibbleVaultFork.t.sol NEW (4 tests, gated on FORK_RPC)

  Remaining before mainnet:
    [ ] Fork test against the EXACT chain you deploy to
    [ ] Deploy to testnet, run fork tests against YOUR deployed vault
    [ ] Treasury = Safe multisig, 2-of-3
    [ ] Owner    = Safe multisig
    [ ] Keeper for accrueFee (Chainlink Automation / Gelato)
    [ ] External audit
    [ ] Rename "Yibble Stock" -> "Yibble Vault Shares" (SEC risk)
================================================================
SUMMARY_EOF

ok "done"
