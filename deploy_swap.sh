#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  ypUSD <-> ybUSD swap layer
#  Deploys YipUSD token + YibbleSwap contract + full test suite
#  Wires existing vault to accept ybUSD from swap output
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

CHAIN=$(curl -s -X POST http://127.0.0.1:8545 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
[ "$CHAIN" = "0x7a69" ] || die "Anvil not running"

cd "$HOME/yibble/contracts" || die "no project"

# ---------- 1. YipUSD token ----------
info "writing src/YipUSD.sol"
cat > src/YipUSD.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Yipple-side USD. Companion to ybUSD.
///         6 decimals to match ybUSD / USDC. Owner-gated mint.
contract YipUSD is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Yipple USD", "ypUSD")
        Ownable(initialOwner)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
SOL_EOF
ok "YipUSD.sol written"

# ---------- 2. YibbleSwap contract ----------
info "writing src/YibbleSwap.sol"
cat > src/YibbleSwap.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice 1:1 swap between ypUSD (input) and ybUSD (output).
///         Treasury funds the ybUSD reserve; ypUSD received goes to treasury.
///
/// @dev    Rate is fixed at 1:1 minus a small fee (default 0.10%).
///         If ypUSD ever trades off-peg, this contract is NOT the venue
///         for that price discovery -- it is a redemption facility.
contract YibbleSwap is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable ypUSD;
    IERC20 public immutable ybUSD;
    address public treasury;
    uint16  public feeBps;           // e.g. 10 = 0.10%
    uint256 public constant MAX_FEE_BPS = 100;  // never more than 1%

    uint256 public totalYpReceived;
    uint256 public totalYbPaidOut;

    event Swapped(
        address indexed user,
        uint256 ypIn,
        uint256 ybOut,
        uint256 feeTaken
    );
    event TreasuryUpdated(address indexed prev, address indexed next);
    event FeeUpdated(uint16 prev, uint16 next);
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);

    error FeeTooHigh(uint16 fee);
    error ZeroAmount();
    error InsufficientReserve(uint256 requested, uint256 available);

    constructor(
        IERC20 ypUSD_,
        IERC20 ybUSD_,
        address treasury_,
        uint16 feeBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(ypUSD_) != address(0), "ypUSD=0");
        require(address(ybUSD_) != address(0), "ybUSD=0");
        require(treasury_ != address(0), "treasury=0");
        require(feeBps_ <= MAX_FEE_BPS, "fee too high");

        ypUSD = ypUSD_;
        ybUSD = ybUSD_;
        treasury = treasury_;
        feeBps = feeBps_;
    }

    // ---------- user-facing ----------

    /// @notice Swap ypUSD for ybUSD at 1:1 minus fee.
    /// @param  ypAmount   amount of ypUSD to spend
    /// @param  minYbOut   slippage guard (pass 0 to disable)
    /// @return ybOut      amount of ybUSD received
    function swapYpForYb(uint256 ypAmount, uint256 minYbOut)
        external
        nonReentrant
        returns (uint256 ybOut)
    {
        if (ypAmount == 0) revert ZeroAmount();

        uint256 fee = (ypAmount * feeBps) / 10_000;
        ybOut = ypAmount - fee;

        uint256 reserve = ybUSD.balanceOf(address(this));
        if (reserve < ybOut) revert InsufficientReserve(ybOut, reserve);
        require(ybOut >= minYbOut, "slippage");

        // Pull ypUSD in, send it to treasury
        ypUSD.safeTransferFrom(msg.sender, treasury, ypAmount);

        // Send ybUSD out
        ybUSD.safeTransfer(msg.sender, ybOut);

        totalYpReceived += ypAmount;
        totalYbPaidOut   += ybOut;

        emit Swapped(msg.sender, ypAmount, ybOut, fee);
    }

    // ---------- view ----------

    /// @notice Preview a swap without executing it.
    function quote(uint256 ypAmount)
        external
        view
        returns (uint256 ybOut, uint256 fee)
    {
        fee   = (ypAmount * feeBps) / 10_000;
        ybOut = ypAmount - fee;
    }

    /// @notice Current ybUSD reserve available to pay out.
    function reserve() external view returns (uint256) {
        return ybUSD.balanceOf(address(this));
    }

    // ---------- owner ----------

    /// @notice Fund the ybUSD reserve (owner pre-approves this contract).
    function fundReserve(uint256 ybAmount) external nonReentrant {
        if (ybAmount == 0) revert ZeroAmount();
        ybUSD.safeTransferFrom(msg.sender, address(this), ybAmount);
        emit ReserveFunded(msg.sender, ybAmount);
    }

    /// @notice Withdraw excess ybUSD reserve (owner only).
    function withdrawReserve(uint256 ybAmount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        ybUSD.safeTransfer(to, ybAmount);
        emit ReserveWithdrawn(to, ybAmount);
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "treasury=0");
        emit TreasuryUpdated(treasury, t);
        treasury = t;
    }

    function setFeeBps(uint16 f) external onlyOwner {
        if (f > MAX_FEE_BPS) revert FeeTooHigh(f);
        emit FeeUpdated(feeBps, f);
        feeBps = f;
    }
}
SOL_EOF
ok "YibbleSwap.sol written"

# ---------- 3. tests ----------
info "writing test/YibbleSwap.t.sol"
cat > test/YibbleSwap.t.sol <<'TEST_EOF'
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
TEST_EOF
ok "tests written"

# ---------- 4. build + test ----------
info "forge build"
forge build || die "build failed"
ok "build passed"

info "forge test --match-contract YibbleSwapTest -vv"
forge test --match-contract YibbleSwapTest -vv || die "swap tests failed"
ok "all swap tests passed"

# ---------- 5. deploy ----------
info "writing script/DeploySwap.s.sol"
cat > script/DeploySwap.s.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YipUSD} from "../src/YipUSD.sol";
import {YibbleUSD} from "../src/YibbleUSD.sol";
import {YibbleSwap} from "../src/YibbleSwap.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeploySwap is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Read existing vault USD address from env or use env-provided
        address ybUSDAddr = vm.envAddress("YBUSD_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        vm.startBroadcast(deployerKey);

        // Deploy ypUSD token
        YipUSD ypUSD = new YipUSD(deployer);
        console.log("YipUSD deployed:", address(ypUSD));

        // Deploy swap with 0.10% fee, treasury = deployer
        YibbleSwap swap = new YibbleSwap(
            IERC20(address(ypUSD)),
            IERC20(ybUSDAddr),
            deployer,       // treasury receives ypUSD
            10,             // 0.10% fee
            deployer
        );
        console.log("YibbleSwap deployed:", address(swap));

        // Fund swap reserve with 100,000 ybUSD (deployer must own these)
        IERC20 ybUSD = IERC20(ybUSDAddr);
        uint256 reserve = 100_000e6;
        require(ybUSD.balanceOf(deployer) >= reserve, "deployer needs 100k ybUSD");
        ybUSD.approve(address(swap), reserve);
        swap.fundReserve(reserve);
        console.log("Reserve funded:", reserve);

        // Mint 1,000,000 ypUSD to deployer for distribution
        ypUSD.mint(deployer, 1_000_000e6);
        console.log("Deployer ypUSD:", ypUSD.balanceOf(deployer));

        vm.stopBroadcast();

        console.log("");
        console.log("== wiring ==");
        console.log("Vault   :", vaultAddr);
        console.log("ybUSD   :", ybUSDAddr);
        console.log("ypUSD   :", address(ypUSD));
        console.log("Swap    :", address(swap));
    }
}
SOL_EOF
ok "deploy script written"

# ---------- 6. run deploy ----------
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RUN_JSON="broadcast/DeployLocal.s.sol/31337/run-latest.json"
[ -f "$RUN_JSON" ] || die "no original deploy - run deploy_local.sh first"
VAULT=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleVault'][0])")
YBUSD=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleUSD'][0])")
info "existing YibbleVault: $VAULT"
info "existing YibbleUSD : $YBUSD"

info "deploying YipUSD + YibbleSwap"
PRIVATE_KEY="$ANVIL_KEY" \
VAULT_ADDRESS="$VAULT" \
YBUSD_ADDRESS="$YBUSD" \
forge script script/DeploySwap.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vv || die "deploy failed"
ok "swap layer deployed"

# ---------- 7. demo: swap then deposit ----------
info "running end-to-end demo (swap ypUSD -> ybUSD, deposit into vault)"
cat > swap_demo.py <<'PY_EOF'
#!/usr/bin/env python3
"""Demo: ypUSD -> ybUSD swap, then ybUSD -> YIB deposit."""
import os, json
from pathlib import Path
from web3 import Web3
from eth_account import Account

RPC = "http://127.0.0.1:8545"
DEC = 6
UNIT = 10 ** DEC
KEY_CEO   = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY_ALICE = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

w3 = Web3(Web3.HTTPProvider(RPC))
ceo   = Account.from_key(KEY_CEO)
alice = Account.from_key(KEY_ALICE)

# Load addresses from broadcast files
def load_addr(name, path):
    txs = json.loads(Path(path).read_text())["transactions"]
    return Web3.to_checksum_address(
        [t["contractAddress"] for t in txs if t.get("contractName") == name][0]
    )

vault_addr = load_addr("YibbleVault", "broadcast/DeployLocal.s.sol/31337/run-latest.json")
yb_addr    = load_addr("YibbleUSD",   "broadcast/DeployLocal.s.sol/31337/run-latest.json")
yp_addr    = load_addr("YipUSD",      "broadcast/DeploySwap.s.sol/31337/run-latest.json")
swap_addr  = load_addr("YibbleSwap",  "broadcast/DeploySwap.s.sol/31337/run-latest.json")

ERC20_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
]
SWAP_ABI = [
    {"inputs":[{"type":"uint256"},{"type":"uint256"}],"name":"swapYpForYb","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"quote","outputs":[{"type":"uint256"},{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"reserve","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
]
VAULT_ABI = [
    {"inputs":[{"type":"uint256"},{"type":"address"}],"name":"deposit","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
]

yp   = w3.eth.contract(address=yp_addr,    abi=ERC20_ABI)
yb   = w3.eth.contract(address=yb_addr,    abi=ERC20_ABI)
swap = w3.eth.contract(address=swap_addr,  abi=SWAP_ABI)
vault = w3.eth.contract(address=vault_addr, abi=VAULT_ABI)

def send(acct, fn, gas=500_000):
    tx = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": gas, "gasPrice": w3.eth.gas_price,
    })
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1: raise RuntimeError(f"reverted: {h.hex()}")
    return r

def f(x): return x / UNIT

print(f"Vault   : {vault_addr}")
print(f"ybUSD   : {yb_addr}")
print(f"ypUSD   : {yp_addr}")
print(f"Swap    : {swap_addr}")
print()

# CEO mints ypUSD to alice (in production, alice would buy on market)
yp_amt = 1_000 * UNIT
print(f"[1] CEO mints {f(yp_amt):,.0f} ypUSD to alice")
tx = yp.functions.mint(alice.address, yp_amt).build_transaction({
    "from": ceo.address, "nonce": w3.eth.get_transaction_count(ceo.address),
    "gas": 100_000, "gasPrice": w3.eth.gas_price,
})
s = ceo.sign_transaction(tx)
r = w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(s.raw_transaction))
print(f"    gas: {r.gasUsed:,}")
print(f"    alice ypUSD: {f(yp.functions.balanceOf(alice.address).call()):,.2f}")
print()

# Quote
(q_out, q_fee) = swap.functions.quote(yp_amt).call()
print(f"[2] Quote: {f(yp_amt):,.0f} ypUSD -> {f(q_out):,.2f} ybUSD (fee {f(q_fee):,.4f})")
print(f"    reserve before: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# Approve + swap
print(f"[3] Alice approves swap, executes swapYpForYb")
send(alice, yp.functions.approve(swap_addr, yp_amt))
yb_before = yb.functions.balanceOf(alice.address).call()
send(alice, swap.functions.swapYpForYb(yp_amt, 0))
yb_after = yb.functions.balanceOf(alice.address).call()
print(f"    alice ybUSD: {f(yb_before):,.2f} -> {f(yb_after):,.2f}  (+{f(yb_after-yb_before):,.4f})")
print(f"    reserve after: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# Deposit into vault
print(f"[4] Alice deposits ybUSD into YibbleVault -> gets YIB shares")
send(alice, yb.functions.approve(vault_addr, yb_after))
send(alice, vault.functions.deposit(yb_after, alice.address))
yib_bal = vault.functions.balanceOf(alice.address).call()
print(f"    alice YIB: {f(yib_bal):,.2f}")
print(f"    vault AUM: {f(vault.functions.totalAssets().call()):,.2f} ybUSD")
print(f"    vault supply: {f(vault.functions.totalSupply().call()):,.2f} YIB")
print()

print("=" * 60)
print("FULL FLOW COMPLETE")
print("=" * 60)
print(f"  ypUSD -> swap -> ybUSD -> deposit -> YIB")
print(f"  {f(yp_amt):,.0f} ypUSD in -> {f(yib_bal):,.2f} YIB out")
print(f"  Round-trip loss: {f(yp_amt - yib_bal):,.4f} ({100*(1-yib_bal/yp_amt):.3f}%)")
print("=" * 60)
PY_EOF
python3 swap_demo.py || die "demo failed"
ok "swap demo complete"

# ---------- 8. summary ----------
cat <<DONE_EOF

================================================================
  YPUSD <-> YBUSD SWAP LAYER DEPLOYED
================================================================
  New contracts:
    YipUSD     : (see deploy output above)
    YibbleSwap : (see deploy output above)

  Flow:
    ypUSD --[swapYpForYb]--> ybUSD --[deposit]--> YIB

  Fee:
    0.10% taken from ypUSD on swap, kept as ypUSD in treasury
    (changeable by owner up to MAX_FEE_BPS = 1%)

  Reserve model:
    Swap holds a ybUSD reserve funded by the owner.
    Each swap: pulls ypUSD to treasury, pays ybUSD from reserve.
    When reserve runs low, owner tops it up with fundReserve().

  What this is:
    A redemption facility. 1 ypUSD is worth 1 ybUSD by decree.

  What this is NOT:
    A price-discovery mechanism. If ypUSD ever trades below 1 ybUSD
    on a real market, this contract becomes an arbitrage source
    (buy cheap ypUSD elsewhere, redeem here for 1 ybUSD). The fee
    (0.10%) is your only protection against that; if you ever see
    ypUSD trading at 0.98 on an exchange, someone is draining your
    reserve at 0.999 each. Raise the fee or pause the swap.

  Contract state you can inspect:
    swap.reserve()              ybUSD currently backing ypUSD
    swap.totalYpReceived()      lifetime ypUSD swapped in
    swap.totalYbPaidOut()       lifetime ybUSD paid out
    swap.feeBps()               current fee

  Admin functions (owner only):
    swap.setFeeBps(n)           change fee (max 100 = 1%)
    swap.setTreasury(addr)      change where ypUSD goes
    swap.fundReserve(amount)    top up ybUSD reserve
    swap.withdrawReserve(a,to)  pull ybUSD out

  Next real decisions:
    [ ] Who supplies the ybUSD reserve at real scale?  (You, per the
        current model -- this is market-making, capital-intensive.)
    [ ] Or: is ypUSD minted 1:1 when ybUSD is deposited somewhere else
        (like a synthetic deposit receipt)? That's a different design
        that doesn't require a reserve.
    [ ] Legal: is a 1:1 redeemable token a security? A deposit? A
        money transmission product? This is the biggest risk, bigger
        than anything in the contract.
================================================================
DONE_EOF

ok "done"
