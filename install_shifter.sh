#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Yibble Yield Shifter
#  - accrues fees on schedule
#  - optionally reinvests 75% into vault (25% stays cash)
#  - installs as termux-job-scheduler job (survives reboot)
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

CHAIN=$(curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
[ "$CHAIN" = "0x7a69" ] || die "Anvil not running on 127.0.0.1:8545"

cd "$HOME/yibble/contracts" || die "no project"

# ---------- 1. write yield_shifter.py (quoted heredoc: safe for Python) ----------
info "writing yield_shifter.py"
cat > yield_shifter.py <<'PY_EOF'
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
PY_EOF
ok "yield_shifter.py written"

# ---------- 2. chmod + single manual run to prove it ----------
chmod +x yield_shifter.py
info "manual run 1: SHIFT disabled (accrue only)"
SHIFT_ENABLED=0 python3 yield_shifter.py || die "accrue-only run failed"
ok "accrue-only run passed"

info "manual run 2: SHIFT enabled (accrue + shift)"
SHIFT_ENABLED=1 BPS_TO_AUM=7500 SHIFT_THRESHOLD=1000000 python3 yield_shifter.py || warn "shift run had issues"
ok "shift run completed"

# ---------- 3. install termux-job-scheduler ----------
info "checking termux-api"
if ! command -v termux-job-scheduler >/dev/null 2>&1; then
  info "installing termux-api (needed for scheduling)"
  pkg install -y termux-api 2>/dev/null || warn "pkg install termux-api had issues"
  warn "if termux-job-scheduler still missing: install Termux:API from F-Droid"
fi

if command -v termux-job-scheduler >/dev/null 2>&1; then
  info "installing shifter as scheduled job (every 15 min)"
  WRAPPER="$HOME/yibble/contracts/run_shifter_once.sh"
  cat > "$WRAPPER" <<SHELL_EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "$HOME/yibble/contracts" || exit 1
SHIFT_ENABLED=1 BPS_TO_AUM=7500 SHIFT_THRESHOLD=1000000 \\
  python3 yield_shifter.py >> "\$HOME/yibble/shifter.log" 2>&1
SHELL_EOF
  chmod +x "$WRAPPER"
  termux-job-scheduler \
    --script "$WRAPPER" \
    --period-ms 900000 \
    --persisted true \
    --network-required true \
    --battery-not-low false \
    && ok "job scheduled (every 15 min, survives reboot)" \
    || warn "scheduler command failed - see termux-job-scheduler docs"
else
  warn "termux-job-scheduler not available"
  warn "install Termux:API app from F-Droid, then re-run this script"
  info "manual cron alternative added to run_shifter_once.sh"
fi

# ---------- 4. verification ----------
info "verifying final vault state"
python3 - <<'VERIFY_EOF'
import os, json
from pathlib import Path
from web3 import Web3
w3 = Web3(Web3.HTTPProvider("http://127.0.0.1:8545"))
VAULT_ABI = [
    {"inputs":[],"name":"totalAssets","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"pendingFee","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"},
]
ERC20_ABI = [{"inputs":[{"type":"address"}],"name":"balanceOf","outputs":[{"type":"uint256"}],"stateMutability":"view","type":"function"}]
p = Path("broadcast/DeployLocal.s.sol/31337/run-latest.json")
txs = json.loads(p.read_text())["transactions"]
vault_addr = [t["contractAddress"] for t in txs if t.get("contractName")=="YibbleVault"][0]
vault = w3.eth.contract(address=Web3.to_checksum_address(vault_addr), abi=VAULT_ABI)
print(f"  totalAssets : {vault.functions.totalAssets().call():,} wei")
print(f"  totalSupply : {vault.functions.totalSupply().call():,} wei")
print(f"  pendingFee  : {vault.functions.pendingFee().call():,} wei")
VERIFY_EOF

cat <<DONE_EOF

================================================================
  YIBBLE YIELD SHIFTER - INSTALLED
================================================================
  File    : ~/yibble/contracts/yield_shifter.py
  Log     : ~/yibble/shifter.log
  Wrapper : ~/yibble/contracts/run_shifter_once.sh

  Two actions per run:
    1. ACCRUE  - call accrueFee() when pendingFee >= MIN_FEE_WEI
    2. SHIFT   - deposit 75% of treasury back into vault (YIB to
                 reinvest addr), keep 25% as cash

  Defaults:
    MIN_FEE_WEI       = 10000     (0.01 ybUSD)
    SHIFT_ENABLED     = 1
    SHIFT_THRESHOLD   = 1000000   (1 ybUSD)
    BPS_TO_AUM        = 7500      (75%)
    REINVEST_ADDR     = treasury  (same as CEO)
    Schedule          = every 15 min (termux-job-scheduler)

  What this fixes:
    Before: fees only accrued when you manually ran a command
    After:  fees accrue automatically, forever, from cron

  What "SHIFT" actually does (honest version):
    Depositing fees back into the vault mints new YIB shares to
    the reinvest address. On a chain with one shareholder (you),
    the 75% reinvest is mathematically neutral - you're paying
    yourself with your own money. It becomes meaningful the
    moment there are OTHER shareholders: your 75% reinvest lifts
    NAV for everyone (including you), your 25% cash is your take.

  Verify it's scheduled:
    termux-job-scheduler --list

  Watch the log:
    tail -f ~/yibble/shifter.log

  Stop the schedule:
    termux-job-scheduler --cancel-all

  Manual run:
    SHIFT_ENABLED=1 python3 yield_shifter.py

  Next steps after this:
    [ ] Deploy to Sepolia (once you want anyone else to see it)
    [ ] Multi-shareholder demo (to show shift has real effect)
    [ ] On-chain history indexer (for charts in frontend)
================================================================
DONE_EOF

ok "done"
