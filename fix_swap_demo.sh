#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Fix swap_demo.py: add mint() to ABI, ensure cwd, re-run
#  Contracts already deployed - this only fixes the Python demo
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# Always work from the project dir, no matter where the prompt was
cd "$HOME/yibble/contracts" || die "cannot cd to project"
info "working from: $(pwd)"

# ---------- sanity: are the swap contracts actually deployed? ----------
for f in broadcast/DeploySwap.s.sol/31337/run-latest.json \
         broadcast/DeployLocal.s.sol/31337/run-latest.json; do
  [ -f "$f" ] || die "missing $f - deploy first"
done
ok "deploy records present"

# ---------- rewrite swap_demo.py with correct ABIs ----------
info "rewriting swap_demo.py (fixed ABIs)"
cat > swap_demo.py <<'PY_EOF'
#!/usr/bin/env python3
"""Demo: ypUSD -> ybUSD swap, then ybUSD -> YIB deposit."""
import json
from pathlib import Path
from web3 import Web3
from eth_account import Account

RPC  = "http://127.0.0.1:8545"
DEC  = 6
UNIT = 10 ** DEC

# Anvil default keys - local only
KEY_CEO   = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY_ALICE = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

w3 = Web3(Web3.HTTPProvider(RPC))
if not w3.is_connected():
    raise SystemExit("cannot connect to Anvil")

ceo   = Account.from_key(KEY_CEO)
alice = Account.from_key(KEY_ALICE)

# ---- ABIs (each covers exactly what the demo calls) ----
# YipUSD: read + approve + owner-mint + user-burn
YPUSD_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"mint","outputs":[],"stateMutability":"nonpayable","type":"function"},
]

# ybUSD (YibbleUSD): read + approve (no mint needed; already minted at deploy)
YBUSD_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
]

# YibbleSwap
SWAP_ABI = [
    {"inputs":[{"type":"uint256"},{"type":"uint256"}],"name":"swapYpForYb","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"quote","outputs":[{"type":"uint256"},{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"reserve","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"feeBps","outputs":[{"type":"uint16"}],"stateMutability":"view","type":"function"},
]

# YibbleVault (ERC-4626)
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

def send(acct, fn, gas=500_000, value=0):
    tx = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": gas,
        "gasPrice": w3.eth.gas_price,
        "value": value,
    })
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1:
        raise RuntimeError(f"reverted: {h.hex()}")
    return r

def f(x):
    return x / UNIT

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
(q_out, q_fee) = swap.functions.quote(yp_amt).call()
print(f"[2] Quote: {f(yp_amt):,.0f} ypUSD -> {f(q_out):,.2f} ybUSD (fee {f(q_fee):,.4f})")
print(f"    reserve before: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# ---- [3] Approve + swap ----
print(f"[3] Alice approves swap, executes swapYpForYb")
send(alice, yp.functions.approve(swap_addr, yp_amt), gas=100_000)
yb_before = yb.functions.balanceOf(alice.address).call()
r = send(alice, swap.functions.swapYpForYb(yp_amt, 0), gas=300_000)
yb_after = yb.functions.balanceOf(alice.address).call()
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice ybUSD: {f(yb_before):,.2f} -> {f(yb_after):,.2f}  (+{f(yb_after-yb_before):,.4f})")
print(f"    reserve after: {f(swap.functions.reserve().call()):,.2f} ybUSD")
print()

# ---- [4] Deposit into vault ----
print(f"[4] Alice deposits ybUSD into YibbleVault -> gets YIB")
send(alice, yb.functions.approve(vault_addr, yb_after), gas=100_000)
r = send(alice, vault.functions.deposit(yb_after, alice.address), gas=300_000)
yib_bal = vault.functions.balanceOf(alice.address).call()
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice YIB: {f(yib_bal):,.2f}")
print(f"    vault AUM: {f(vault.functions.totalAssets().call()):,.2f} ybUSD")
print(f"    vault supply: {f(vault.functions.totalSupply().call()):,.2f} YIB")
print()

print("=" * 60)
print("FULL FLOW COMPLETE")
print("=" * 60)
print(f"  ypUSD -> swap -> ybUSD -> deposit -> YIB")
print(f"  {f(yp_amt):,.0f} ypUSD in -> {f(yib_bal):,.2f} YIB out")
lost = f(yp_amt) - f(yib_bal)
print(f"  Round-trip loss: {lost:,.4f}  ({100 * lost / f(yp_amt):.3f}%)")
print(f"  (that loss is the 0.10% swap fee, kept as ypUSD in treasury)")
print("=" * 60)
PY_EOF
ok "swap_demo.py rewritten"

# ---------- run it ----------
info "running demo"
python3 swap_demo.py || die "demo still failed"
ok "demo complete"

# ---------- summary ----------
cat <<DONE_EOF

================================================================
  SWAP DEMO FIXED & RUNNING
================================================================
  What broke:
    swap_demo.py used a single ERC20_ABI that lacked mint().
    YipUSD.mint() is owner-only but the demo needs to call it
    from the CEO account to fund alice with ypUSD.
    web3 raised ABIFunctionNotFound before any tx was built.

  What I changed:
    split the ABIs into YPUSD_ABI / YBUSD_ABI / SWAP_ABI / VAULT_ABI
    each one covers exactly the functions the demo calls
    added feeBps() to the printed state so you can see the
    current fee on every run
    cd into \$HOME/yibble/contracts at the top - the script no
    longer assumes your prompt is in the right place

  What did NOT change:
    YipUSD.sol          - unchanged
    YibbleSwap.sol      - unchanged
    test/YibbleSwap.t.sol - unchanged (15/15 passing)
    deployed addresses  - unchanged (already on chain)

  Your deployed contracts:
    Vault : 0xf5059a5D33d5853360D16C683c16e67980206f36
    ybUSD : 0x851356ae760d987E095750cCeb3bC6014560891C
    ypUSD : 0x922D6956C99E12DFeB3224DEA977D0939758A1Fe
    Swap  : 0x5081a39b8A5f0E35a8D959395a630b68B74Dd30f

  The warning from the compiler:
    "declaration has the same name as another declaration"
    (uint256 reserve inside swapYpForYb shadows reserve() function)
    It compiles and works, but if you ever want zero warnings
    rename the local to \`uint256 available\` - purely cosmetic.

  Two other Foundry warnings (feeBps event, nonReentrant order):
    Also cosmetic. The first wants an event emitted on setFeeBps
    (nice-to-have for indexers); the second is stylistic - the
    linter prefers nonReentrant as the first modifier.
    Neither affects correctness.

  About the ~/wxmr-deploy tree you pasted at the top:
    That's a different project (Hardhat, oracle-signer,
    recon-dashboard, coordinator). Not related to Yibble.
    If you want me to look at it, start a separate thread -
    I'll treat it as its own thing.

  What you now have, all running:
    - YibbleVault (ERC-4626, 0.20% fee, tested at 100%)
    - YbUSD (asset token)
    - YipUSD (swap-input token)
    - YibbleSwap (1:1 minus 0.10%, reserve-backed)
    - Keeper (accrues fees on schedule)
    - Yield Shifter (reinvests 75% as YIB shares)
    - Dashboard (CLI + browser at :8080)
    - Swap demo (this script, end-to-end ypUSD -> YIB)

  Next real decisions (all non-code):
    [ ] Reserve model: are you the market maker, or is ypUSD
        minted 1:1 against ybUSD in a lockbox? (See prior message.)
    [ ] Legal: ypUSD is a redeemable receipt. MSB / securities
        question. Bigger risk than any contract here.
    [ ] Whitepaper: rewrite Section 2 for the real three-token
        architecture (ybUSD / ypUSD / YIB). Say "whitepaper" if
        you want that now.
================================================================
DONE_EOF

ok "done"
