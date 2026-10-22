import time
import requests
import subprocess

STELLAR_ACCOUNT = "GAJF4XL6AUJGGXDGSRBFOQ2L3MLMPKXXFYEADABWRJ7F24X6RKUA2FOF"
HORIZON_URL = f"https://horizon-testnet.stellar.org/accounts/{STELLAR_ACCOUNT}/transactions?order=desc&limit=10"

# EVM Config
EVM_RPC = "http://127.0.0.1:8545"
ENGINE_ADDRESS = "0x36C02dA8a0983159322a80FFE9F24b1acfF8B570" # The new engine address
PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

processed_hashes = set()

def check_stellar_for_proofs():
    print("🔍 Reverse Relayer Online. Watching Stellar for valid proofs...")
    
    while True:
        try:
            response = requests.get(HORIZON_URL, timeout=5)
            if response.status_code == 200:
                txs = response.json()['_embedded']['records']
                for tx in txs:
                    tx_hash = tx['hash']
                    memo = tx.get('memo', '')
                    
                    if memo and memo.startswith("BAR") and tx_hash not in processed_hashes:
                        print(f"\n✅ [STELLAR PROOF FOUND] Hash: {tx_hash} | Memo: {memo}")
                        processed_hashes.add(tx_hash)
                        
                        print(f"🚀 Sending proof to EVM to unlock asset...")
                        
                        cmd = [
                            "cast", "send", ENGINE_ADDRESS, 
                            "unlockWithStellarProof(string)", memo, 
                            "--rpc-url", EVM_RPC, 
                            "--private-key", PK
                        ]
                        
                        subprocess.run(cmd, capture_output=True, text=True)
                        print("🎉 [EVM] Asset Successfully Unlocked using Stellar Proof!")
                        
            time.sleep(5)
        except Exception as e:
            print(f"⚠️ Error: {e}")
            time.sleep(5)

if __name__ == "__main__":
    check_stellar_for_proofs()
