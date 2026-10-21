#!/usr/bin/env python3
"""
yield_shifter.py - Yibble Yield Shifter.

Two independent actions per run:
  ACCRUE  if vault.pendingFee() >= MIN_FEE_WEI, call accrueFee()
  SHIFT   if SHIFT_ENABLED and treasury USDC >= SHIFT_THRESHOLD_WEI,
          deposit BPS_TO_AUM% back into vault (YIB -> REINVEST_ADDR),
          keep remainder as cash

Designed to run from cron / termux-job-scheduler. Writes to LOG_FILE.
Exits 0 on success or skip, 1 on error (so scheduler can retry/log).

Env:
  RPC_URL           default http://127.0.0.1:8545
  MIN_FEE_WEI       default 10000       (0.01 ybUSD @ 6dp)
  SHIFT_ENABLED     default 0           ("1" to enable)
  SHIFT_THRESHOLD   default 1000000     (1 ybUSD)
  BPS_TO_AUM        default 7500        (75%)
  REINVEST_ADDR     default treasury addr
  LOG_FILE          default ~/yibble/shifter.log
  TOKEN_DECIMALS    default 6
"""
import os, sys, json, time
from pathlib import Path
from datetime import datetime, timezone
from web3 import Web3
from eth_account import Account

RPC_URL         = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
MIN_FEE_WEI     = int(os.environ.get("MIN_FEE_WEI", "10000"))
SHIFT_ENABLED   = os.environ.get("SHIFT_ENABLED", "0") == "1"
SHIFT_THRESHOLD = int(os.environ.get("SHIFT_THRESHOLD", "1000000"))
BPS_TO_AUM      = int(os.environ.get("BPS_TO_AUM", "7500"))
REINVEST_ADDR   = os.environ.get("REINVEST_ADDR", "")
DECIMALS        = int(os.environ.get("TOKEN_DECIMALS", "6"))
LOG_FILE        = Path(os.environ.get("LOG_FILE", str(Path.home() / "yibble" / "shifter.log")))

ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

VAULT_ABI = [
    {"inputs":[],"name":"totalAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"pendingFee","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"treasury","outputs":[{"type":"address"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"asset","outputs":[{"type":"address"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"accrueFee","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"},{"type":"address"}],"name":"deposit","outputs":[{"type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"type":"uint256"}],"name":"convertToShares","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
]
ERC20_ABI = [
    {"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"type":"address"},{"type":"uint256"}],"name":"approve","outputs":[{"type":"bool"}],"stateMutability":"nonpayable","type":"function"},
]

def log(msg):
    line = f"[{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}] {msg}"
    print(line)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(line + "\n")
    except Exception:
        pass  # never let logging kill the run

def load_vault():
    if os.environ.get("VAULT_ADDRESS"):
        return Web3.to_checksum_address(os.environ["VAULT_ADDRESS"])
    p = Path("broadcast/DeployLocal.s.sol/31337/run-latest.json")
    if not p.exists():
        log(f"FAIL: no VAULT_ADDRESS and no {p}")
        sys.exit(1)
    for tx in json.loads(p.read_text())["transactions"]:
        if tx.get("contractName") == "YibbleVault":
            return Web3.to_checksum_address(tx["contractAddress"])
    log("FAIL: YibbleVault not in broadcast")
    sys.exit(1)

def send(w3, acct, fn, gas=800_000):
    tx = fn.build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": gas,
        "gasPrice": w3.eth.gas_price,
    })
    signed = acct.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=90)
    if r.status != 1:
        raise RuntimeError(f"tx reverted: {h.hex()}")
    return r

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        log(f"FAIL: cannot connect to {RPC_URL}")
        return 1

    vault_addr = load_vault()
    acct = Account.from_key(ANVIL_KEY)
    vault = w3.eth.contract(address=vault_addr, abi=VAULT_ABI)
    treasury_addr = Web3.to_checksum_address(vault.functions.treasury().call())
    usd_addr = Web3.to_checksum_address(vault.functions.asset().call())
    usd = w3.eth.contract(address=usd_addr, abi=ERC20_ABI)

    log(f"--- run: block {w3.eth.block_number} ---")

    # ---- ACCRUE ----
    pending = vault.functions.pendingFee().call()
    log(f"pending fee: {pending:,} wei  (threshold {MIN_FEE_WEI:,})")
    accrued = 0
    if pending >= MIN_FEE_WEI:
        try:
            r = send(w3, acct, vault.functions.accrueFee())
            accrued = pending
            log(f"ACCRUE ok: gas {r.gasUsed:,}, block {r.blockNumber}")
        except Exception as e:
            log(f"ACCRUE failed: {e}")
            return 1
    else:
        log("ACCRUE skip: below threshold")

    # ---- SHIFT ----
    if not SHIFT_ENABLED:
        log("SHIFT disabled (set SHIFT_ENABLED=1 to enable)")
        return 0

    balance = usd.functions.balanceOf(treasury_addr).call()
    log(f"treasury balance: {balance:,} wei  (threshold {SHIFT_THRESHOLD:,})")
    if balance < SHIFT_THRESHOLD:
        log("SHIFT skip: below threshold")
        return 0

    reinvest = Web3.to_checksum_address(REINVEST_ADDR) if REINVEST_ADDR else treasury_addr
    to_aum = (balance * BPS_TO_AUM) // 10000
    to_cash = balance - to_aum
    log(f"SHIFT plan: {to_aum:,} to AUM, {to_cash:,} as cash, reinv={reinvest}")

    # treasury must approve vault to pull ybUSD. Only works if signer==treasury.
    if acct.address.lower() != treasury_addr.lower():
        log(f"SHIFT blocked: signer {acct.address} != treasury {treasury_addr}")
        return 0

    try:
        approve_r = send(w3, acct, usd.functions.approve(vault_addr, to_aum), gas=100_000)
        log(f"APPROVE ok: gas {approve_r.gasUsed:,}")

        shares_before = vault.functions.totalSupply().call()
        dep_r = send(w3, acct, vault.functions.deposit(to_aum, reinvest), gas=300_000)
        shares_after = vault.functions.totalSupply().call()
        minted = shares_after - shares_before
        log(f"DEPOSIT ok: {to_aum:,} -> {minted:,} YIB to {reinvest}")
        log(f"  cash retained: {to_cash:,} wei")
    except Exception as e:
        log(f"SHIFT failed: {e}")
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
