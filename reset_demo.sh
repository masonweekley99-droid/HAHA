#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
GRN=$'\e[32m'; RST=$'\e[0m'
ok() { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }

# Kill anything listening on 8545, restart Anvil fresh
pkill -f "anvil" 2>/dev/null || true
sleep 1
cd "$HOME/yibble/contracts" || exit 1
nohup anvil >/tmp/anvil.log 2>&1 &
sleep 3

# Verify chain
CHAIN=$(curl -s -X POST http://127.0.0.1:8545 -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
[ "$CHAIN" = "0x7a69" ] || { echo "anvil failed to start"; cat /tmp/anvil.log; exit 1; }
ok "anvil restarted (fresh chain, block 0)"

# Re-deploy everything from scratch
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

PRIVATE_KEY="$ANVIL_KEY" forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast >/dev/null 2>&1 || { echo "deploy local failed"; exit 1; }
ok "YibbleUSD + YibbleVault re-deployed"

RUN_JSON="broadcast/DeployLocal.s.sol/31337/run-latest.json"
VAULT=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleVault'][0])")
YBUSD=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleUSD'][0])")

PRIVATE_KEY="$ANVIL_KEY" VAULT_ADDRESS="$VAULT" YBUSD_ADDRESS="$YBUSD" \
  forge script script/DeploySwap.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast >/dev/null 2>&1 || { echo "deploy swap failed"; exit 1; }
ok "YipUSD + YibbleSwap re-deployed"

echo
echo "Fresh state:"
echo "  Vault : $VAULT"
echo "  ybUSD : $YBUSD"
echo "  ypUSD : $(python3 -c "import json;d=json.load(open('broadcast/DeploySwap.s.sol/31337/run-latest.json'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YipUSD'][0])")"
echo "  Swap  : $(python3 -c "import json;d=json.load(open('broadcast/DeploySwap.s.sol/31337/run-latest.json'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleSwap'][0])")"
echo
echo "Now run: python3 swap_demo.py"
