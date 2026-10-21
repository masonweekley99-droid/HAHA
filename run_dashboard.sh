#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Live dashboard for YibbleVault.
#  --once   single snapshot (good for cron / scripted checks)
#  --loop   live-refreshing table (default)
#  --json   machine-readable snapshot for piping
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
ok "Anvil running, chain 31337"

cd "$HOME/yibble/contracts" || die "no project"

if ! python3 -c "import web3" 2>/dev/null; then
  info "installing web3"
  pip install --quiet web3 eth-account || die "pip install failed"
fi
ok "python deps ready"

info "writing dashboard.py"
cat > dashboard.py <<'PY_EOF'
#!/usr/bin/env python3
"""
dashboard.py - live view of the YibbleVault.

Reads on-chain state, computes share price, pending fee, and time-to-next-
viable-accrual. Loops with a fixed refresh, or --once for a snapshot.

Modes:
    python3 dashboard.py            live loop, refresh every REFRESH_SEC
    python3 dashboard.py --once     one snapshot, exit
    python3 dashboard.py --json     one JSON snapshot, exit (for piping)
"""
import os
import sys
import time
import json
import argparse
from pathlib import Path
from datetime import datetime, timezone

from web3 import Web3

RPC_URL       = os.environ.get("RPC_URL", "http://127.0.0.1:8545")
REFRESH_SEC   = int(os.environ.get("REFRESH_SEC", "10"))
DECIMALS      = int(os.environ.get("TOKEN_DECIMALS", "6"))
MIN_FEE_WEI   = int(os.environ.get("MIN_FEE_WEI", "10000"))  # 0.01 ybUSD @ 6dp
MGMT_FEE_BPS  = 20                                            # 0.20% annual
YEAR_SEC      = 365 * 24 * 3600

VAULT_ABI = [
    {"inputs": [], "name": "totalAssets",  "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "totalSupply",  "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "pendingFee",   "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "lastAccrual",  "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "treasury",     "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "asset",        "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"inputs": [{"type": "uint256", "name": "shares"}], "name": "convertToAssets",
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"inputs": [{"type": "uint256", "name": "assets"}], "name": "convertToShares",
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

ERC20_ABI = [
    {"inputs": [{"type": "address", "name": "a"}], "name": "balanceOf",
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]


def fmt(amount, decimals=DECIMALS, width=15):
    return f"{amount / 10 ** decimals:>{width},.4f}"


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
    print("[FAIL] YibbleVault not found")
    sys.exit(1)


def snapshot(w3, vault, ybusd, treasury_addr):
    assets      = vault.functions.totalAssets().call()
    supply      = vault.functions.totalSupply().call()
    pending     = vault.functions.pendingFee().call()
    last        = vault.functions.lastAccrual().call()
    now         = w3.eth.get_block("latest").timestamp
    treasury_b  = ybusd.functions.balanceOf(treasury_addr).call()
    block       = w3.eth.block_number

    # share price: how many assets 1 full share (1eDECIMALS) is worth
    unit_share  = 10 ** DECIMALS
    price_wei   = vault.functions.convertToAssets(unit_share).call()

    # time until pendingFee crosses MIN_FEE_WEI (linear estimate)
    # annual fee on current AUM = assets * MGMT_FEE_BPS / 10000
    annual_fee  = assets * MGMT_FEE_BPS // 10000
    if pending >= MIN_FEE_WEI:
        secs_to_min = 0
    elif annual_fee == 0:
        secs_to_min = None
    else:
        secs_to_min = int((MIN_FEE_WEI - pending) * YEAR_SEC / annual_fee)

    return dict(
        block=block,
        now=now,
        last=last,
        elapsed=now - last,
        assets=assets,
        supply=supply,
        price_wei=price_wei,
        pending=pending,
        annual_fee=annual_fee,
        treasury_bal=treasury_b,
        secs_to_min=secs_to_min,
        min_fee_wei=MIN_FEE_WEI,
    )


def humanize_seconds(s):
    if s is None:   return "n/a (empty vault)"
    if s <= 0:      return "READY NOW"
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    if d: return f"{d}d {h:02d}h"
    if h: return f"{h}h {m:02d}m"
    if m: return f"{m}m {s:02d}s"
    return f"{s}s"


def render(snap):
    # clear + cursor home (works in Termux)
    sys.stdout.write("\033[2J\033[H")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")

    print(f"{'=' * 60}")
    print(f"  YIBBLE VAULT DASHBOARD           {ts}")
    print(f"{'=' * 60}")
    print(f"  block                 : {snap['block']:>15,}")
    print(f"  chain time            : {snap['now']}")
    print()
    print(f"  totalAssets           : {fmt(snap['assets'])} ybUSD")
    print(f"  totalSupply           : {fmt(snap['supply'])} YIB")
    print(f"  share price (1 YIB)   : {fmt(snap['price_wei'])} ybUSD")
    print(f"  treasury balance      : {fmt(snap['treasury_bal'])} ybUSD")
    print()
    print(f"  pendingFee            : {fmt(snap['pending'])} ybUSD")
    print(f"  annualFeeRate         : {fmt(snap['annual_fee'])} ybUSD/yr  (0.20%)")
    print(f"  min accrual threshold : {fmt(snap['min_fee_wei'])} ybUSD")
    print(f"  next accrual in       : {humanize_seconds(snap['secs_to_min']):>15}")
    print(f"  last accrual          : {snap['last']}  ({snap['elapsed']:,}s ago)")
    print()

    # one-line status
    if snap['pending'] >= snap['min_fee_wei']:
        status = "\033[32m● FEES READY\033[0m  - keeper should accrue"
    elif snap['supply'] == 0:
        status = "\033[33m● EMPTY VAULT\033[0m - deposit to start fee accrual"
    else:
        status = "\033[36m● ACCRUING\033[0m     - fees building"
    print(f"  status                : {status}")
    print(f"{'=' * 60}")
    print(f"  refresh every {REFRESH_SEC}s   Ctrl+C to quit")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print(f"[FAIL] cannot connect to {RPC_URL}")
        sys.exit(1)

    vault_addr    = load_vault_address()
    vault         = w3.eth.contract(address=vault_addr, abi=VAULT_ABI)
    treasury_addr = Web3.to_checksum_address(vault.functions.treasury().call())
    usd_addr      = Web3.to_checksum_address(vault.functions.asset().call())
    ybusd         = w3.eth.contract(address=usd_addr, abi=ERC20_ABI)

    if args.json or args.once:
        snap = snapshot(w3, vault, ybusd, treasury_addr)
        if args.json:
            print(json.dumps(snap, indent=2))
        else:
            render(snap)
        return

    try:
        while True:
            snap = snapshot(w3, vault, ybusd, treasury_addr)
            render(snap)
            time.sleep(REFRESH_SEC)
    except KeyboardInterrupt:
        print("\n[INFO] dashboard stopped")


if __name__ == "__main__":
    main()
PY_EOF
ok "dashboard.py written"

# ---------- run once to prove it ----------
info "running dashboard --once"
python3 dashboard.py --once || die "dashboard failed"

# ---------- json mode test ----------
info "testing --json (first 12 lines)"
python3 dashboard.py --json | head -12 || true

# ---------- summary ----------
cat <<DONE_EOF

================================================================
  DASHBOARD OPERATIONAL
================================================================
  File    : ~/yibble/contracts/dashboard.py

  Modes:
    python3 dashboard.py            live loop, 10s refresh, clear screen
    python3 dashboard.py --once     single snapshot
    python3 dashboard.py --json     machine-readable, pipe to jq

  What it shows:
    - block number and chain timestamp
    - totalAssets / totalSupply / share price
    - treasury balance
    - pendingFee and annual fee rate
    - next accrual countdown (or "READY NOW")
    - status line (ACCRUING / FEES READY / EMPTY VAULT)

  The countdown math:
    annual_fee = totalAssets * 0.20%
    next_accrual = (MIN_FEE_WEI - pendingFee) * YEAR_SEC / annual_fee

    Right now with 99,800 ybUSD AUM and 0.01 threshold:
      annual_fee = 199.6 ybUSD
      time_to_0.01 = 0.01 * 31,536,000 / 199.6
                   = ~1,580 seconds  (~26 minutes)

    That's the number the keeper is racing against.

  Combine with keeper (run in two terminals):
    Terminal 1: python3 dashboard.py
    Terminal 2: python3 keeper.py --loop   (or just python3 keeper.py)

    Watch the countdown hit zero, then the keeper's accrual shows up in
    the next dashboard refresh.

  Env overrides:
    RPC_URL, REFRESH_SEC, TOKEN_DECIMALS, MIN_FEE_WEI, VAULT_ADDRESS

  Sample one-liner for scripts:
    python3 dashboard.py --json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['pending'])"

  Next step (#3): frontend dashboard (React/Vite)
    Same reads, rendered in a browser. Say "3" when ready.
================================================================
DONE_EOF

ok "done"
