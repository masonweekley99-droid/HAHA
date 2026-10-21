#!/usr/bin/env python3
"""
Multi-shareholder flywheel demo.

Deploys FRESH YibbleUSD + YibbleVault.
Funds CEO (account 0), Alice (account 1), Bob (account 2).
Alice deposits 100,000 ybUSD. Bob deposits 50,000. CEO starts at 0.
Runs 5 years of: warp, accrueFee, then SHIFT (75% reinject, 25% CEO cash).
Prints a year-by-year table of each holder's value.

Leaves the existing deployed vault untouched.
"""
import os, sys, json, time
from pathlib import Path
from web3 import Web3
from eth_account import Account

RPC     = "http://127.0.0.1:8545"
DEC     = 6
UNIT    = 10 ** DEC
YEARS   = 5

# Anvil default keys (local only)
KEY_CEO   = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
KEY_ALICE = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
KEY_BOB   = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"

VAULT_ABI = [
    {"inputs":[],"name":"totalAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"pendingFee","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"treasury","outputs":[{"type":"address"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"asset","outputs":[{"type":"address"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"uint256"},{"type":"address"}],"name":"deposit","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"convertToAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"accrueFee","outputs":[],"stateMutability":"nonpayable","type":"function"},
]
ERC20_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"mint","outputs":[],"stateMutability":"nonpayable","type":"function"},
]

def send(w3, acct, fn, gas=800_000):
    tx = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": gas, "gasPrice": w3.eth.gas_price,
    })
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1:
        raise RuntimeError(f"tx reverted: {h.hex()}")
    return r

def load_artifact(path):
    with open(path) as f:
        a = json.load(f)
    return a["abi"], a["bytecode"]["object"]

def deploy(w3, acct, abi, bytecode, *args):
    c = w3.eth.contract(abi=abi, bytecode=bytecode)
    tx = c.constructor(*args).build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": 3_000_000, "gasPrice": w3.eth.gas_price,
    })
    s = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(s.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1:
        raise RuntimeError(f"deploy reverted: {h.hex()}")
    return r.contractAddress

def warp_year(w3):
    w3.provider.make_request("evm_increaseTime", [365 * 24 * 3600])
    w3.provider.make_request("evm_mine", [])

def f(wei):
    return wei / UNIT

def print_header():
    print()
    print("=" * 100)
    print(f"{'Year':<5} {'AUM':>12} {'Supply':>12} {'Price':>9} "
          f"{'Alice$':>11} {'Bob$':>10} {'CEO$':>10} {'CEOsh':>10} {'CEOcash':>10}")
    print("-" * 100)

def print_row(year, vault, usd, alice, bob, ceo):
    aum    = vault.functions.totalAssets().call()
    supply = vault.functions.totalSupply().call()
    price  = vault.functions.convertToAssets(UNIT).call()
    a_sh   = vault.functions.balanceOf(alice.address).call()
    b_sh   = vault.functions.balanceOf(bob.address).call()
    c_sh   = vault.functions.balanceOf(ceo.address).call()
    a_val  = vault.functions.convertToAssets(a_sh).call()
    b_val  = vault.functions.convertToAssets(b_sh).call()
    c_val  = vault.functions.convertToAssets(c_sh).call()
    c_cash = usd.functions.balanceOf(ceo.address).call()
    # CEO$ = value of CEO shares (cash shown separately)
    print(f"{year:<5} {f(aum):>12,.0f} {f(supply):>12,.0f} {f(price):>9.4f} "
          f"{f(a_val):>11,.2f} {f(b_val):>10,.2f} {f(c_val):>10,.2f} "
          f"{f(c_sh):>10,.0f} {f(c_cash):>10,.2f}")

def main():
    w3 = Web3(Web3.HTTPProvider(RPC))
    if not w3.is_connected():
        print("FAIL: no RPC"); return 1

    ceo   = Account.from_key(KEY_CEO)
    alice = Account.from_key(KEY_ALICE)
    bob   = Account.from_key(KEY_BOB)

    print("[INFO] deploying fresh YibbleUSD + YibbleVault")
    usd_abi, usd_bc   = load_artifact("out/YibbleUSD.sol/YibbleUSD.json")
    vault_abi, v_bc   = load_artifact("out/YibbleVault.sol/YibbleVault.json")

    usd_addr = deploy(w3, ceo, usd_abi, usd_bc, ceo.address)
    print(f"  USD   : {usd_addr}")

    # Vault constructor: (asset, treasury, owner) - matches our OZ v5 contract
    vault_addr = deploy(w3, ceo, vault_abi, v_bc,
                        Web3.to_checksum_address(usd_addr),
                        ceo.address, ceo.address)
    print(f"  Vault : {vault_addr}")

    usd   = w3.eth.contract(address=Web3.to_checksum_address(usd_addr),   abi=ERC20_ABI + VAULT_ABI[0:0])
    usd   = w3.eth.contract(address=Web3.to_checksum_address(usd_addr),   abi=ERC20_ABI)
    vault = w3.eth.contract(address=Web3.to_checksum_address(vault_addr), abi=VAULT_ABI)

    # fund Alice 100k, Bob 50k
    print("[INFO] funding accounts")
    send(w3, ceo, usd.functions.mint(alice.address, 100_000 * UNIT))
    send(w3, ceo, usd.functions.mint(bob.address,    50_000 * UNIT))

    # deposits
    print("[INFO] alice deposits 100,000 ybUSD")
    send(w3, alice, usd.functions.approve(vault_addr, 100_000 * UNIT))
    send(w3, alice, vault.functions.deposit(100_000 * UNIT, alice.address))

    print("[INFO] bob deposits 50,000 ybUSD")
    send(w3, bob,   usd.functions.approve(vault_addr, 50_000 * UNIT))
    send(w3, bob,   vault.functions.deposit(50_000 * UNIT, bob.address))

    print_header()
    print_row(0, vault, usd, alice, bob, ceo)

    for year in range(1, YEARS + 1):
        # 1 year passes
        warp_year(w3)

        # accrue fees
        try:
            send(w3, ceo, vault.functions.accrueFee())
        except Exception as e:
            print(f"  [WARN] accrue failed year {year}: {e}")

        # SHIFT: CEO deposits 75% of own ybUSD balance back into vault
        ceo_balance = usd.functions.balanceOf(ceo.address).call()
        to_deposit = (ceo_balance * 7500) // 10000
        if to_deposit > 0:
            try:
                send(w3, ceo, usd.functions.approve(vault_addr, to_deposit))
                send(w3, ceo, vault.functions.deposit(to_deposit, ceo.address))
            except Exception as e:
                print(f"  [WARN] shift failed year {year}: {e}")

        print_row(year, vault, usd, alice, bob, ceo)

    print("-" * 100)
    print()
    print("Reading the table:")
    print("  AUM       = total assets under management (declines by net fees)")
    print("  Supply    = total YIB shares outstanding (grows via CEO reinvestment)")
    print("  Price     = ybUSD per 1 YIB (declines by 0.20%/yr minus what CEO reinjects)")
    print("  Alice$    = current ybUSD value of Alice's shares")
    print("  Bob$      = current ybUSD value of Bob's shares")
    print("  CEO$      = current ybUSD value of CEO's shares (from reinvestment)")
    print("  CEOsh     = CEO's YIB share count")
    print("  CEOcash   = ybUSD cash the CEO has taken as fee (the 25% not reinvested)")
    print()
    print(f"New vault: {vault_addr}")
    print(f"New USD  : {usd_addr}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
