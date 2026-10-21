import time
import requests
import json
from stellar_sdk import Server, Keypair, TransactionBuilder, Network, Asset

# --- CONFIGURATION ---
EVM_RPC_URL = "http://127.0.0.1:8545"
ENGINE_ADDRESS = "0x84eA74d481Ee0A5332c457a4d796187F6Ba67fEB" # Update if redeployed

# Event Topics
TOPIC_BITCOIN_REVIVED = "0x4e6eb050f0090ed1a6213e4d2c2b806dbca771d0eb043b9f6a5b5c4b60142d95"
TOPIC_BARGRAPH = "0x" + "".join(["%02x" % ord(c) for c in "BarGraphUpdate(address,uint256,uint256,string)"]) # Placeholder - use ethers to hash this if needed

STELLAR_SECRET = "SCUJJWLA5FV3EKEJORSYLD32EI7YKBZPIH2IXCET5HTQ3WTE4NUVQI27" 
STELLAR_HORIZON = "https://horizon-testnet.stellar.org"

server = Server(horizon_url=STELLAR_HORIZON)
keypair = Keypair.from_secret(STELLAR_SECRET)

def send_stellar_proof(tx_hash, event_type):
    try:
        account = server.load_account(keypair.public_key)
        memo_text = f"{event_type}:{tx_hash[:20]}"
        tx = (
            TransactionBuilder(account, Network.TESTNET_NETWORK_PASSPHRASE, 100)
            .append_payment_op(destination=keypair.public_key, amount="0.00001", asset=Asset.native())
            .add_text_memo(memo_text)
            .set_timeout(30)
            .build()
        )
        tx.sign(keypair)
        response = server.submit_transaction(tx)
        print(f"✅ [STELLAR PROOF] TX: {response['hash']} | Memo: {memo_text}")
    except Exception as e:
        print(f"❌ [STELLAR ERROR] {e}")

def poll_evm_events():
    print("🚀 RELAYER ONLINE. Watching for VRT trades, Ticks, and Revivals...")
    last_block = 0
    
    while True:
        try:
            payload = {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}
            res = requests.post(EVM_RPC_URL, json=payload, timeout=5).json()
            current_block = int(res['result'], 16)
            
            if current_block > last_block:
                # Get ALL logs from the Engine address
                payload = {
                    "jsonrpc":"2.0","method":"eth_getLogs","params":[{
                        "fromBlock": hex(last_block + 1),
                        "toBlock": hex(current_block),
                        "address": ENGINE_ADDRESS
                    }],"id":1
                }
                logs_res = requests.post(EVM_RPC_URL, json=payload, timeout=5).json()
                
                if 'result' in logs_res:
                    for log in logs_res['result']:
                        tx_hash = log['transactionHash']
                        topic0 = log['topics'][0]
                        
                        # Check which event fired
                        if topic0 == TOPIC_BITCOIN_REVIVED:
                            print(f"\n🩸 [EVM] Bitcoin Revived: {tx_hash}")
                            send_stellar_proof(tx_hash, "REVIVE")
                        else:
                            # It's likely a BarGraphUpdate (or VerusSold/TimeShift)
                            # We only want to relay the BarGraph updates to avoid spam
                            if len(log['topics']) > 2:
                                bar_id = int(log['topics'][2], 16)
                                print(f"\n📊 [EVM] BarGraph Shift (Bar #{bar_id}): {tx_hash}")
                                send_stellar_proof(tx_hash, f"BAR{bar_id}")
                        
                last_block = current_block
            time.sleep(2)
        except Exception as e:
            time.sleep(2)

if __name__ == "__main__":
    poll_evm_events()
