#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
GRN=$'\e[32m'; RST=$'\e[0m'; CYN=$'\e[36m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '\e[31m[FAIL]\e[0m %s\n' "$*" >&2; exit 1; }

PROJECT="$HOME/yibble/contracts"
[ -d "$PROJECT" ] || die "no project"

# Patch swap_demo.py: resolve paths relative to script location,
# not cwd, so you can invoke it from anywhere.
python3 - <<'PY'
from pathlib import Path
p = Path.home() / "yibble" / "contracts" / "swap_demo.py"
s = p.read_text()

# 1. Anchor all paths to the script's own dir
old_header = '''import json
from pathlib import Path
from web3 import Web3
from eth_account import Account

RPC  = "http://127.0.0.1:8545"'''

new_header = '''import json
import os
from pathlib import Path
from web3 import Web3
from eth_account import Account

# Force cwd to the project dir so relative broadcast/ paths resolve
# regardless of where the script was invoked from.
PROJECT_DIR = Path(__file__).resolve().parent
os.chdir(PROJECT_DIR)

RPC  = "http://127.0.0.1:8545"'''

if old_header not in s:
    raise SystemExit("header anchor not found")
s = s.replace(old_header, new_header)

# 2. Show alice's STARTING balance so accumulation is obvious
old_step4 = '''print(f"[4] Alice deposits ybUSD into YibbleVault -> gets YIB")
send(alice, yb.functions.approve(vault_addr, yb_after), gas=100_000)
r = send(alice, vault.functions.deposit(yb_after, alice.address), gas=300_000)
yib_bal = vault.functions.balanceOf(alice.address).call()
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice YIB: {f(yib_bal):,.2f}")'''

new_step4 = '''print(f"[4] Alice deposits ybUSD into YibbleVault -> gets YIB")
yib_before = vault.functions.balanceOf(alice.address).call()
send(alice, yb.functions.approve(vault_addr, yb_after), gas=100_000)
r = send(alice, vault.functions.deposit(yb_after, alice.address), gas=300_000)
yib_bal = vault.functions.balanceOf(alice.address).call()
print(f"    gas: {r.gasUsed:,}  block {r.blockNumber}")
print(f"    alice YIB: {f(yib_before):,.2f} -> {f(yib_bal):,.2f}  (+{f(yib_bal-yib_before):,.4f})")'''

if old_step4 not in s:
    raise SystemExit("step4 anchor not found")
s = s.replace(old_step4, new_step4)

p.write_text(s)
print("patched swap_demo.py paths + step4")
PY

ok "patched"

# Run from the project dir explicitly (belt + suspenders)
cd "$PROJECT" || die "cannot cd"
info "running demo from $(pwd)"
python3 swap_demo.py || die "demo failed"
ok "demo complete"
