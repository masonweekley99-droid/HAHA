#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  YibbleVault - Termux Foundry Fix + Build + Test
#  Fixes: "version not found in artifacts for this platform"
#  Writes: contract, test, deploy script, foundry.toml
#  Runs: forge build, forge test -vv
# ============================================================
set -uo pipefail

GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

PROJECT="$HOME/yibble/contracts"
CONTRACT_DIR="$PROJECT/src"
TEST_DIR="$PROJECT/test"
SCRIPT_DIR="$PROJECT/script"

[ -d "$PROJECT" ] || die "Missing $PROJECT - run 'forge init' there first"
cd "$PROJECT" || die "cd $PROJECT failed"
info "project: $PROJECT"

# ---------- 1. system deps ----------
info "installing system packages (clang, make, python, pip, git)"
pkg install -y clang make python pip git >/dev/null 2>&1 \
  || warn "pkg install had issues (continuing anyway)"

# ---------- 2. locate a working solc ----------
SOLC_BIN=""
SOLC_VER=""
try_solc() {
  local path="$1"
  [ -n "$path" ] && [ -x "$path" ] || return 1
  local v
  v=$("$path" --version 2>/dev/null | awk '/Version:/ {print $2; exit}')
  [ -n "$v" ] || return 1
  SOLC_BIN="$path"
  SOLC_VER="$v"
}

# Path A: system solc (Termux pkg)
try_solc "$(command -v solc || true)" || {
  info "no system solc - trying 'pkg install solidity'"
  pkg install -y solidity >/dev/null 2>&1 || warn "pkg solidity failed"
  try_solc "$(command -v solc || true)" || warn "still no system solc"
}

# Path B: solc-select (native arm64 binaries)
if [ -z "$SOLC_BIN" ]; then
  info "falling back to solc-select"
  pip install --quiet solc-select >/dev/null 2>&1 \
    || die "pip install solc-select failed"
  for v in 0.8.30 0.8.28 0.8.26 0.8.24 0.8.20; do
    info "solc-select install $v"
    if solc-select install "$v" >/dev/null 2>&1; then
      solc-select use "$v" >/dev/null 2>&1 || true
      try_solc "$(command -v solc || true)" && break
    fi
  done
fi

[ -n "$SOLC_BIN" ] || die "could not locate any working solc"
ok "solc: $SOLC_BIN ($SOLC_VER)"

# ---------- 3. decide OZ version compatibility ----------
MAJ=$(echo "$SOLC_VER" | cut -d. -f1)
MIN=$(echo "$SOLC_VER" | cut -d. -f2)
PAT=$(echo "$SOLC_VER" | cut -d. -f3 | cut -d+ -f1)
NEED_OZ5=0
if [ "$MAJ" -gt 0 ] || { [ "$MAJ" -eq 0 ] && [ "$MIN" -gt 8 ]; } \
   || { [ "$MAJ" -eq 0 ] && [ "$MIN" -eq 8 ] && [ "$PAT" -ge 20 ]; }; then
  NEED_OZ5=1
fi

if [ "$NEED_OZ5" -eq 1 ]; then
  PRAGMA="^0.8.20"
  ok "solc >= 0.8.20 -> keeping OZ v5"
else
  PRAGMA="^0.8.0"
  warn "solc $SOLC_VER < 0.8.20 -> downgrading OZ to v4.9.x"
  if [ -d lib/openzeppelin-contracts/.git ]; then
    ( cd lib/openzeppelin-contracts \
      && git fetch --tags --quiet \
      && git checkout v4.9.6 --quiet ) \
      || die "OZ downgrade failed"
    ok "OZ pinned to v4.9.6"
  else
    die "lib/openzeppelin-contracts is not a git checkout"
  fi
fi

# ---------- 4. foundry.toml ----------
info "writing foundry.toml"
cat > foundry.toml <<TOML_EOF
[profile.default]
src = "src"
test = "test"
script = "script"
out = "out"
libs = ["lib"]
solc = "$SOLC_BIN"
optimizer = true
optimizer_runs = 200
via_ir = false
evm_version = "paris"

[profile.default.fuzz]
runs = 256
TOML_EOF
ok "foundry.toml written"

# ---------- 5. remappings ----------
cat > remappings.txt <<'REM_EOF'
@openzeppelin/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
REM_EOF
ok "remappings.txt written"

# ---------- 6. contract ----------
mkdir -p "$CONTRACT_DIR" "$TEST_DIR" "$SCRIPT_DIR"
cat > "$CONTRACT_DIR/YibbleVault.sol" <<SOL_EOF
// SPDX-License-Identifier: MIT
pragma solidity $PRAGMA;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YibbleVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MGMT_FEE_BPS = 20; // 0.20% annual
    address public treasury;
    uint256 public lastAccrual;

    event TreasuryUpdated(address indexed prev, address indexed next);
    event FeeAccrued(uint256 amount, uint256 timestamp);

    constructor(IERC20 asset_, address treasury_)
        ERC20("Yibble Stock", "YIB")
        ERC4626(asset_)
        Ownable2Step()
    {
        require(treasury_ != address(0), "treasury=0");
        treasury = treasury_;
        lastAccrual = block.timestamp;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "treasury=0");
        emit TreasuryUpdated(treasury, t);
        treasury = t;
    }

    function pendingFee() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrual;
        return (totalAssets() * MGMT_FEE_BPS * elapsed) / (10_000 * 365 days);
    }

    function accrueFee() external {
        uint256 fee = pendingFee();
        if (fee > 0 && fee <= totalAssets()) {
            IERC20(asset()).safeTransfer(treasury, fee);
            emit FeeAccrued(fee, block.timestamp);
        }
        lastAccrual = block.timestamp;
    }
}
SOL_EOF
ok "YibbleVault.sol written"

# ---------- 7. tests ----------
cat > "$TEST_DIR/YibbleVault.t.sol" <<'TEST_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

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
        vault = new YibbleVault(usdc, treasury);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob,   1_000_000e6);
    }

    function testInitialState() public view {
        assertEq(vault.name(), "Yibble Stock");
        assertEq(vault.symbol(), "YIB");
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.treasury(), treasury);
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
        assertEq(gained, 200e6); // 0.20% of 100k
    }

    function testTreasuryZeroReverts() public {
        vm.expectRevert();
        new YibbleVault(usdc, address(0));
    }

    function testOnlyOwnerSetTreasury() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setTreasury(alice);

        vault.setTreasury(bob);
        assertEq(vault.treasury(), bob);
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
TEST_EOF
ok "test file written"

# ---------- 8. deploy script ----------
cat > "$SCRIPT_DIR/Deploy.s.sol" <<'DEPLOY_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeployYibbleVault is Script {
    function run() external {
        address asset    = vm.envAddress("ASSET_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();
        YibbleVault vault = new YibbleVault(IERC20(asset), treasury);
        vm.stopBroadcast();

        console.log("YibbleVault deployed at:", address(vault));
    }
}
DEPLOY_EOF
ok "deploy script written"

# ---------- 9. build ----------
info "forge build"
forge build || die "build failed"

# ---------- 10. test ----------
info "forge test -vv"
forge test -vv || die "tests failed"

# ---------- 11. summary ----------
cat <<SUMMARY_EOF

================================================================
  YIBBLE VAULT BUILD COMPLETE
================================================================
  Project : $PROJECT
  Solc    : $SOLC_BIN
  Version : $SOLC_VER
  Pragma  : $PRAGMA

  Files:
    src/YibbleVault.sol
    test/YibbleVault.t.sol
    script/Deploy.s.sol

  Next:
    forge test -vvv                        # verbose tests
    forge test --match-test testFeeAccrual # single test
    forge coverage                         # coverage report

  Deploy:
    export ASSET_ADDRESS=0x...             # USDC address
    export TREASURY_ADDRESS=0x...          # your Safe/EOA
    forge script script/Deploy.s.sol \\
        --rpc-url \$RPC_URL --broadcast
================================================================
SUMMARY_EOF

ok "done"
