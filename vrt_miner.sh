#!/bin/bash
RPC="http://127.0.0.1:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
VRT_ADDRESS="0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"
TARGET_WALLET="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
MINE_AMOUNT="10000000000000000000" 

echo "⛏️  VRT MINER STARTED"
echo "=================================================="
echo "🎯 VRT: $VRT_ADDRESS"
echo "🎯 Target: $TARGET_WALLET"
echo "=================================================="

BLOCK_COUNT=0
while true; do
    if ! cast block-number --rpc-url $RPC > /dev/null 2>&1; then
        echo -e "\n❌ LOST CONNECTION TO ANVIL"
        exit 1
    fi
    cast send $VRT_ADDRESS "transfer(address,uint256)" $TARGET_WALLET $MINE_AMOUNT       --rpc-url $RPC --private-key $PK > /dev/null 2>&1
    BLOCK_COUNT=$((BLOCK_COUNT + 1))
    BALANCE=$(cast call $VRT_ADDRESS "balanceOf(address)(uint256)" $TARGET_WALLET --rpc-url $RPC 2>/dev/null | awk '{print $1}')
    printf "\r⛏️  Mined #%d | VRT Balance: %s    " "$BLOCK_COUNT" "$BALANCE"
    sleep 2
done
