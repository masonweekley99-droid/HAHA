#!/usr/bin/env python3
"""
keeper.py - accrueFee() keeper for YibbleVault.

Reads vault address from broadcast/DeployLocal.s.sol/31337/run-latest.json
(or VAULT_ADDRESS env). Signs with Anvil account 0 (public test key,
valid only on local chain). Accrues when pendingFee >= MIN_FEE_WEI.

Modes:
    python3 keeper.py --status   print state, exit
    python3 keeper.py --once     single check, maybe accrue, exit
    python3 keeper.py --demo     warp Anvil time +1yr, accrue, show before/after
    python3 keeper.py            loop, check every INTERVAL_SEC seconds
"""
import os
import sys
import time
import json
import argparse
from pathlib import Path

from web3 import Web3
from eth_account import Account

RPC_URL      = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
MIN_FEE_WEI  = int(os.environ.get("MIN_FEE_WEI", "10000"))   # 0.01 ybUSD @ 6dp
INTERVAL_SEC = int(os.environ.get("INTERVAL_SEC", "60"))
DECIMALS     = int(os.environ.get("TOKEN_DECIMALS", "6"))

# Anvil account 0. Public test key. Only valid on local Anvil.
ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

VAULT_ABI = [
    {"inputs": [], "name": "totalAssets", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "totalSupply", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "pendingFee",  "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastAccrual", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "treasury",    "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "asset",       "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "accrueFee",   "outputs": [], "stateMutability": "nonpayable", "type": "function"},
]

ERC20_ABI = [
    {"inputs": [{"type": "address", "name": "account"}], "name": "balanceOf",
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]


def fmt(amount, decimals=DECIMALS):
    return f"{amount / 10 ** decimals:>15,.4f}"


def load_vault_address():
    if os.environ.get("VAULT_ADDRESS"):
        return Web3.to_checksum_address(os.environ["VAULT_ADDRESS"])
    path = Path("broadcast/DeployLocal.s.sol/31337/run-latest.json")
    if not path.exists():
        print(f"[FAIL] no VAULT_ADDRESS and no {path}")
        sys.exit(1)
    data = json.loads(path.read_text())
    for tx in data["transactions"]:
        if tx.get("contractName") == "YibbleVault":
            return Web3.to_checksum_address(tx["contractAddress"])
    print("[FAIL] YibbleVault not found in broadcast JSON")
    sys.exit(1)


def snapshot(vault, ybusd, treasury, w3):
    assets  = vault.functions.totalAssets().call()
    supply  = vault.functions.totalSupply().call()
    pending = vault.functions.pendingFee().call()
    last    = vault.functions.lastAccrual().call()
    now     = w3.eth.get_block("latest").timestamp
    tre_b   = ybusd.functions.balanceOf(treasury).call()
    return dict(assets=assets, supply=supply, pending=pending,
                last=last, now=now, treasury_bal=tre_b,
                elapsed=now - last)


def print_state(s, label):
    print(f"  == {label} ==")
    print(f"  totalAssets      : {s['assets']:>20,} wei   ({fmt(s['assets'])} ybUSD)")
    print(f"  totalSupply      : {s['supply']:>20,} wei   ({fmt(s['supply'])} YIB)")
    print(f"  treasury balance : {s['treasury_bal']:>20,} wei   ({fmt(s['treasury_bal'])} ybUSD)")
    print(f"  pendingFee       : {s['pending']:>20,} wei   ({fmt(s['pending'])} ybUSD)")
    print(f"  lastAccrual      : {s['last']}")
    print(f"  now              : {s['now']}   (elapsed {s['elapsed']:,}s)")
    print()


def warp_time(w3, seconds):
    w3.provider.make_request("evm_increaseTime", [seconds])
    w3.provider.make_request("evm_mine", [])


def accrue(vault, ybusd, treasury, w3, account):
    pending = vault.functions.pendingFee().call()
    if pending == 0:
        print("  [skip] pendingFee is 0")
        return None
    before = ybusd.functions.balanceOf(treasury).call()
    tx = vault.functions.accrueFee().build_transaction({
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
        "gas": 500_000,
        "gasPrice": w3.eth.gas_price,
    })
    signed = account.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"  [tx] {h.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(h, timeout=60)
    if receipt.status != 1:
        print(f"  [FAIL] reverted")
        return None
    after = ybusd.functions.balanceOf(treasury).call()
    actual = after - before
    print(f"  [OK] receipt: block {receipt.blockNumber}, gas {receipt.gasUsed:,}")
    print(f"  [OK] treasury delta: +{actual:,} wei  ({fmt(actual)} ybUSD)")
    return actual


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--once",   action="store_true")
    ap.add_argument("--demo",   action="store_true")
    args = ap.parse_args()

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print(f"[FAIL] cannot connect to {RPC_URL}")
        sys.exit(1)

    vault_addr    = load_vault_address()
    account       = Account.from_key(ANVIL_KEY)
    vault         = w3.eth.contract(address=vault_addr, abi=VAULT_ABI)
    treasury_addr = Web3.to_checksum_address(vault.functions.treasury().call())
    usd_addr      = Web3.to_checksum_address(vault.functions.asset().call())
    ybusd         = w3.eth.contract(address=usd_addr, abi=ERC20_ABI)

    print(f"[INFO] vault    : {vault_addr}")
    print(f"[INFO] asset    : {usd_addr}")
    print(f"[INFO] treasury : {treasury_addr}")
    print(f"[INFO] signer   : {account.address}")
    print()

    s0 = snapshot(vault, ybusd, treasury_addr, w3)
    print_state(s0, "before")

    if args.status:
        return

    if args.demo:
        print("  [warp] advancing Anvil +1 year")
        warp_time(w3, 365 * 24 * 3600)
        s1 = snapshot(vault, ybusd, treasury_addr, w3)
        print_state(s1, "after warp")
        print("  [accrue] calling accrueFee()")
        accrue(vault, ybusd, treasury_addr, w3, account)
        s2 = snapshot(vault, ybusd, treasury_addr, w3)
        print_state(s2, "after accrue")
        return

    if args.once:
        print(f"  threshold: {MIN_FEE_WEI:,} wei")
        if s0["pending"] >= MIN_FEE_WEI:
            accrue(vault, ybusd, treasury_addr, w3, account)
        else:
            print(f"  [skip] pending {s0['pending']:,} < {MIN_FEE_WEI:,}")
        return

    print(f"[INFO] loop mode: every {INTERVAL_SEC}s, threshold {MIN_FEE_WEI:,} wei")
    print("[INFO] Ctrl+C to stop")
    print()
    try:
        while True:
            s = snapshot(vault, ybusd, treasury_addr, w3)
            tag = time.strftime("%H:%M:%S")
            if s["pending"] >= MIN_FEE_WEI:
                print(f"[{tag}] pending {s['pending']:,} >= {MIN_FEE_WEI:,} - accruing")
                accrue(vault, ybusd, treasury_addr, w3, account)
            else:
                print(f"[{tag}] pending {s['pending']:,} < {MIN_FEE_WEI:,} - skip")
            time.sleep(INTERVAL_SEC)
    except KeyboardInterrupt:
        print("\n[INFO] keeper stopped")


if __name__ == "__main__":
    main()
