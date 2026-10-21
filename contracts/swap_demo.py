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
