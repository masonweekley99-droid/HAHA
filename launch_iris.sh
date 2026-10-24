#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔥 STARTING IRIS PROTOCOL...${NC}"

# 1. Kill old Anvil and start fresh
pkill -9 -f anvil
sleep 1
nohup anvil --host 127.0.0.1 --port 8545 > anvil.log 2>&1 &
sleep 3

if ! cast block-number --rpc-url http://127.0.0.1:8545 > /dev/null 2>&1; then
    echo -e "${RED}❌ Anvil failed to start. Check anvil.log${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Anvil is LIVE.${NC}"

# 2. Setup Variables
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC="http://127.0.0.1:8545"
ME="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# 3. Deploy Tokens
echo "🪙 Deploying VRT..."
VRT=$(forge create src/VerusToken.sol:VerusToken --rpc-url $RPC --private-key $PK --broadcast | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $3}')

echo "🪙 Deploying BTC..."
BTC=$(forge create src/MockWBTC.sol:MockWBTC --rpc-url $RPC --private-key $PK --broadcast | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $3}')

echo "✅ VRT: $VRT | BTC: $BTC"

# 4. Deploy Bank Iris
echo "🏦 Deploying Bank Iris..."
IRIS=$(forge create src/BankIris.sol:BankIris --rpc-url $RPC --private-key $PK --broadcast --constructor-args $VRT | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $3}')
echo "✅ IRIS: $IRIS"

# 5. Deploy Engine
echo "⚙️ Deploying IdentityShiftEngine..."
ENGINE=$(forge create src/IdentityShiftEngine.sol:IdentityShiftEngine --rpc-url $RPC --private-key $PK --broadcast --constructor-args $VRT $VRT $BTC $IRIS | grep -oE 'Deployed to: 0x[a-fA-F0-9]{40}' | awk '{print $3}')
echo "✅ ENGINE: $ENGINE"

# 6. Approve and Trigger Trade
echo "🔓 Approving Engine to spend VRT..."
cast send $VRT "approve(address,uint256)" $ENGINE 1000000000000000000000000 --rpc-url $RPC --private-key $PK > /dev/null

echo "🩸 Triggering 1,000,000 VRT Sell..."
cast send $ENGINE "simulateVerusSell(address,uint256)" $ME 1000000000000000000000000 --rpc-url $RPC --private-key $PK > /dev/null

# 7. Verify
echo "=================================================="
echo -e "${GREEN}👑 BANK IRIS VRT BALANCE:${NC}"
cast call $VRT "balanceOf(address)(uint256)" $IRIS --rpc-url $RPC
echo -e "${GREEN}👤 YOUR REMAINING VRT BALANCE:${NC}"
cast call $VRT "balanceOf(address)(uint256)" $ME --rpc-url $RPC
echo "=================================================="
echo -e "${GREEN}✅ IRIS PROTOCOL EXECUTED.${NC}"

# Save addresses
cat > ~/vault_test/addresses.env << EOL
export VRT_ADDRESS="$VRT"
export BTC_ADDRESS="$BTC"
export IRIS_ADDRESS="$IRIS"
export ENGINE_ADDRESS="$ENGINE"
export PK="$PK"
export RPC="$RPC"
EOL
