#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  YibbleVault Patch - OZ v5 Ownable(msg.sender) fix
#  Rewrites contract + tests with correct constructor chain
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

# ---------- 1. rewrite contract with Ownable(msg.sender) ----------
info "rewriting src/YibbleVault.sol"
cat > src/YibbleVault.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YibbleVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant MGMT_FEE_BPS = 20; // 0.20% annual
    address public treasury;
    uint256 public lastAccrual;

    event TreasuryUpdated(address indexed prev, address indexed next);
    event FeeAccrued(uint256 amount, uint256 timestamp);

    constructor(IERC20 asset_, address treasury_, address initialOwner)
        ERC20("Yibble Stock", "YIB")
        ERC4626(asset_)
        Ownable(initialOwner)
    {
        require(treasury_ != address(0), "treasury=0");
        require(initialOwner != address(0), "owner=0");
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
ok "contract written"

# ---------- 2. rewrite test to match new constructor ----------
info "rewriting test/YibbleVault.t.sol"
cat > test/YibbleVault.t.sol <<'TEST_EOF'
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
        vm.expectRevert(bytes("owner=0"));
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
TEST_EOF
ok "test written"

# ---------- 3. rewrite deploy script for new constructor ----------
info "rewriting script/Deploy.s.sol"
cat > script/Deploy.s.sol <<'DEPLOY_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeployYibbleVault is Script {
    function run() external {
        address asset    = vm.envAddress("ASSET_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address owner    = vm.envOr("OWNER_ADDRESS", msg.sender);

        vm.startBroadcast();
        YibbleVault vault = new YibbleVault(IERC20(asset), treasury, owner);
        vm.stopBroadcast();

        console.log("YibbleVault   :", address(vault));
        console.log("asset         :", asset);
        console.log("treasury      :", treasury);
        console.log("owner         :", owner);
    }
}
DEPLOY_EOF
ok "deploy script written"

# ---------- 4. clean stale artifacts ----------
info "cleaning stale artifacts"
rm -rf out cache broadcast 2>/dev/null || true
ok "clean"

# ---------- 5. build ----------
info "forge build"
if ! forge build; then
  die "build still failing - see error above"
fi
ok "build passed"

# ---------- 6. test ----------
info "forge test -vv"
if ! forge test -vv; then
  die "tests failing - see error above"
fi
ok "tests passed"

# ---------- 7. summary ----------
cat <<SUMMARY_EOF

================================================================
  YIBBLE VAULT - BUILD & TEST PASSED
================================================================
  Contract : src/YibbleVault.sol
  Tests    : test/YibbleVault.t.sol
  Deploy   : script/Deploy.s.sol

  Constructor signature:
    YibbleVault(IERC20 asset_, address treasury_, address initialOwner)

  What changed vs previous build:
    - Ownable(initialOwner) now passed explicitly (OZ v5 requirement)
    - initialOwner added as third constructor arg
    - testOwnershipTwoStepTransfer added (verifies Ownable2Step)
    - testOwnerZeroReverts added
    - Deploy script reads OWNER_ADDRESS env (defaults to msg.sender)

  Next steps:
    forge test -vvv                            # verbose test output
    forge test --match-test testFeeAccrual     # single test
    forge coverage                             # coverage report
    forge inspect YibbleVault abi              # ABI dump

  Deploy to testnet:
    export ASSET_ADDRESS=0x...                 # USDC address
    export TREASURY_ADDRESS=0x...              # Safe/multisig
    export OWNER_ADDRESS=0x...                 # deployer or Safe
    export RPC_URL=https://...
    forge script script/Deploy.s.sol \\
      --rpc-url \$RPC_URL --broadcast --verify

  Security checklist before mainnet:
    [ ] Treasury is a Safe multisig (2-of-3 minimum)
    [ ] Owner is a Safe multisig, not an EOA
    [ ] ASSET_ADDRESS is real USDC on target chain
    [ ] accrueFee() has a keeper (Chainlink Automation / Gelato)
    [ ] External audit completed
================================================================
SUMMARY_EOF

ok "done"
