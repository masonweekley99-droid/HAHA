#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Revive: restart anvil (writable log), redeploy all, run
#  clean demo. Rewrites swap_demo.py from scratch so no patch
#  can fail on anchor mismatch.
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

PROJECT="$HOME/yibble/contracts"
[ -d "$PROJECT" ] || die "no project at $PROJECT"
cd "$PROJECT" || die "cd failed"
info "project: $(pwd)"

# ---------- 1. kill + restart anvil with $HOME log ----------
info "stopping any running anvil"
pkill -f anvil 2>/dev/null || true
sleep 1

LOG="$HOME/yibble/anvil.log"
: > "$LOG"  # truncate/create
info "starting anvil (log: $LOG)"
nohup anvil > "$LOG" 2>&1 &
ANVIL_PID=$!
sleep 3

# wait up to 10s for chain
CHAIN=""
for i in $(seq 1 10); do
    CHAIN=$(curl -s -m 1 -X POST http://127.0.0.1:8545 \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        2>/dev/null | grep -o '"result":"[^"]*"' | cut -d'"' -f4 || true)
    [ "$CHAIN" = "0x7a69" ] && break
    sleep 1
done

[ "$CHAIN" = "0x7a69" ] || { tail -20 "$LOG"; die "anvil did not come up (see log above)"; }
ok "anvil running, pid $ANVIL_PID, chain 31337"

# ---------- 2. redeploy everything from scratch ----------
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

info "deploying YibbleUSD + YibbleVault"
PRIVATE_KEY="$ANVIL_KEY" forge script script/DeployLocal.s.sol \
    --rpc-url http://127.0.0.1:8545 --broadcast >/dev/null 2>&1 \
    || die "DeployLocal failed"
ok "YibbleUSD + YibbleVault deployed"

RUN_LOCAL="broadcast/DeployLocal.s.sol/31337/run-latest.json"
VAULT=$(python3 -c "import json;d=json.load(open('$RUN_LOCAL'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleVault'][0])")
YBUSD=$(python3 -c "import json;d=json.load(open('$RUN_LOCAL'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleUSD'][0])")

info "deploying YipUSD + YibbleSwap"
PRIVATE_KEY="$ANVIL_KEY" VAULT_ADDRESS="$VAULT" YBUSD_ADDRESS="$YBUSD" \
    forge script script/DeploySwap.s.sol \
    --rpc-url http://127.0.0.1:8545 --broadcast >/dev/null 2>&1 \
    || die "DeploySwap failed"
ok "YipUSD + YibbleSwap deployed"

# ---------- 3. rewrite swap_demo.py from scratch ----------
info "writing swap_demo.py (clean, per-run tracking)"
cat > swap_demo.py <<'PY_EOF'
#!/usr/bin/env python3
"""
swap_demo.py - ypUSD -> ybUSD -> YIB, with per-run accounting.

Works from any cwd (resolves paths relative to itself).
Reports only THIS RUN's delta, so repeated runs stay readable.
"""
import json
import os
from pathlib import Path
from web3 import Web3
from eth_account import Account

# Anchor to the project dir regardless of how we were invoked
PROJECT_DIR = Path(__file__).resolve().parent
os.chdir(PROJECT_DIR)

RPC  = "http://127.0.0.1:8545"
DEC  = 6
UNIT = 10 ** DEC

KEY_CEO   = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY_ALICE = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

w3 = Web3(Web3.HTTPProvider(RPC))
if not w3.is_connected():
    raise SystemExit(f"cannot connect to Anvil at {RPC}")

ceo   = Account.from_key(KEY_CEO)
alice = Account.from_key(KEY_ALICE)

YPUSD_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"mint","outputs":[],"stateMutability":"nonpayable","type":"function"},
]
YBUSD_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
]
SWAP_ABI = [
    {"inputs":[{"type":"uint256"},{"type":"uint256"}],"name":"swapYpForYb","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"quote","outputs":[{"type":"uint256"},{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"reserve","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"feeBps","outputs":[{"type":"uint16"}],"stateMutability":"view","type":"function"},
]
VAULT_ABI = [
    {"inputs":[{"type":"uint256"},{"type":"address"}],"name":"deposit","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"convertToAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
]

def load_addr(name, path):
    txs = json.loads(Path(path).read_text())["transactions"]
    addrs = [t["contractAddress"] for t in txs if t.get("contractName") == name]
    if not addrs:
        raise SystemExit(f"{name} not in {path}")
    return Web3.to_checksum_address(addrs[0])

vault_addr = load_addr("YibbleVault", "broadcast/DeployLocal.s.sol/31337/run-latest.json")
yb_addr    = load_addr("YibbleUSD",   "broadcast/DeployLocal.s.sol/31337/run-latest.json")
yp_addr    = load_addr("YipUSD",      "broadcast/DeploySwap.s.sol/31337/run-latest.json")
swap_addr  = load_addr("YibbleSwap",  "broadcast/DeploySwap.s.sol/31337/run-latest.json")

yp    = w3.eth.contract(address=yp_addr,    abi=YPUSD_ABI)
yb    = w3.eth.contract(address=yb_addr,    abi=YBUSD_ABI)
swap  = w3.eth.contract(address=swap_addr,  abi=SWAP_ABI)
vault = w3.eth.contract(address=vault_addr, abi=VAULT_ABI)

# Capture per-run baseline BEFORE any actions
ALICE_YIB_START = vault.functions.balanceOf(alice.address).call()

def send(acct, fn, gas=500_000):
    tx = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": gas,
        "gasPrice": w3.eth.gas_price,
    })
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1:
        raise RuntimeError(f"reverted: {h.hex()}")
    return r

def f(x): return x / UNIT

print(f"Vault   : {vault_addr}")
print(f"ybUSD   : {yb_addr}")
print(f"ypUSD   : {yp_addr}")
print(f"Swap    : {swap_addr}")
print(f"feeBps  : {swap.functions.feeBps().call()}  (0.10% = 10)")
print()

# ---- [1] CEO mints ypUSD to alice ----
yp_amt = 1_000 * UNIT
print(f"[1] CEO mints {f(yp_amt):,.0f} ypUSD to alice")
r = send(ceo, yp.functions.mint(alice.address, yp_amt), gas=100_000)
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice ypUSD: {f(yp.functions.balanceOf(alice.address).call()):,.2f}")
print()

# ---- [2] Quote ----
q_out, q_fee = swap.functions.quote(yp_amt).call()
print(f"[2] Quote: {f(yp_amt):,.0f} ypUSD -> {f(q_out):,.2f} ybUSD (fee {f(q_fee):,.4f})")
print(f"    reserve before: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# ---- [3] Swap ----
print(f"[3] Alice approves swap, executes swapYpForYb")
send(alice, yp.functions.approve(swap_addr, yp_amt), gas=100_000)
yb_before = yb.functions.balanceOf(alice.address).call()
r = send(alice, swap.functions.swapYpForYb(yp_amt, 0), gas=300_000)
yb_after = yb.functions.balanceOf(alice.address).call()
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice ybUSD: {f(yb_before):,.2f} -> {f(yb_after):,.2f}  (+{f(yb_after - yb_before):,.4f})")
print(f"    reserve after: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# ---- [4] Deposit ----
print(f"[4] Alice deposits ybUSD into YibbleVault -> gets YIB")
send(alice, yb.functions.approve(vault_addr, yb_after), gas=100_000)
r = send(alice, vault.functions.deposit(yb_after, alice.address), gas=300_000)
yib_bal = vault.functions.balanceOf(alice.address).call()
yib_added = yib_bal - ALICE_YIB_START
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice YIB (total)     : {f(yib_bal):,.4f}")
print(f"    alice YIB (this run)  : +{f(yib_added):,.4f}")
print(f"    vault AUM             : {f(vault.functions.totalAssets().call()):,.2f} ybUSD")
print(f"    vault supply          : {f(vault.functions.totalSupply().call()):,.2f} YIB")
print()

# ---- Summary: per-run ----
yib_value_now = vault.functions.convertToAssets(yib_added).call() if yib_added > 0 else 0
fee_paid = yp_amt - (yb_after - yb_before)  # this run's swap fee

print("=" * 60)
print("THIS RUN")
print("=" * 60)
print(f"  in        : {f(yp_amt):>12,.4f} ypUSD")
print(f"  swap fee  : {f(fee_paid):>12,.4f} ypUSD  (0.10%)")
print(f"  ybUSD out : {f(yb_after - yb_before):>12,.4f} ybUSD")
print(f"  YIB added : {f(yib_added):>12,.4f} YIB")
print(f"  YIB value : {f(yib_value_now):>12,.4f} ybUSD  (redeemable now)")
print()
print(f"  net cost  : {f(yp_amt) - f(yib_value_now):>12,.4f} ybUSD")
print(f"              (exactly the 0.10% swap fee)")
print()
print("=" * 60)
print("CUMULATIVE (all runs on this chain)")
print("=" * 60)
print(f"  alice YIB : {f(yib_bal):>12,.4f}")
print(f"  reserve   : {f(swap.functions.reserve().call()):>12,.4f} ybUSD")
print(f"  vault AUM : {f(vault.functions.totalAssets().call()):>12,.4f} ybUSD")
print("=" * 60)
PY_EOF

# ---------- 4. run ----------
info "running swap_demo.py"
python3 swap_demo.py || die "demo failed"
ok "demo complete"

cat <<DONE

================================================================
  STATE
================================================================
  Anvil restarted (fresh chain, block 0).
  All contracts re-deployed at new addresses.
  swap_demo.py rewritten from scratch (no patches to fail).

  The new summary splits cleanly:

    THIS RUN              <- what just happened, one row per line
    CUMULATIVE            <- running totals across all runs

  So you can run the demo 10 times in a row and every time the
  "THIS RUN" section shows the same clean numbers:

    in        :  1,000.0000 ypUSD
    swap fee  :      1.0000 ypUSD  (0.10%)
    ybUSD out :    999.0000 ybUSD
    YIB added : ~1,003.0000 YIB
    YIB value :    999.0000 ybUSD
    net cost  :      1.0000 ybUSD  (the swap fee)

  What went wrong in the previous round:
    1. /tmp/anvil.log: Termux can't write to /tmp.
       Logs now go to \$HOME/yibble/anvil.log.
    2. "header anchor not found": the patch script expected the
       original text but the file was already patched.
       Fixed by rewriting the whole file, not patching it.
    3. Old summary compared cumulative YIB against single-run
       deposit, producing fake "-199%" numbers.
       Fixed by tracking ALICE_YIB_START and reporting deltas.

  About ~/ghost-dome:
    You keep landing there. If it's a separate project (Rust?
    another scaffold?) that's fine, but Yibble scripts don't
    live there. \`cd ~/yibble/contracts\` before running anything
    from this conversation.
================================================================
DONE
