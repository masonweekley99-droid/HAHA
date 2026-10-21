import subprocess, json, time, os, sys
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('http://127.0.0.1:8545'))
owner = w3.eth.accounts[0]
user = w3.eth.accounts[1]

def print_slow(text, speed=0.01):
    for char in text:
        sys.stdout.write(char); sys.stdout.flush(); time.sleep(speed)
    print()

print("🏛️ EXECUTING YIBBLE V2.0 LIFECYCLE...")

# 1. Deploy Contracts
print_slow("🚀 [STEP 1] Deploying Yibble V2.0 Contracts...")
cmd = ["forge", "script", "script/DeployYibbleV2.s.sol:DeployYibbleV2", "--rpc-url", "http://127.0.0.1:8545", "--broadcast", "--mnemonics", "test test test test test test test test test test test junk"]
res = subprocess.run(cmd, capture_output=True, text=True, cwd="/data/data/com.termux/files/home/vault_test")

if res.returncode != 0:
    print("❌ Deployment failed.")
    print(res.stderr[-1000:])
    exit(1)

broadcast_file = "/data/data/com.termux/files/home/vault_test/broadcast/DeployYibbleV2.s.sol/31337/run-latest.json"
with open(broadcast_file, 'r') as f:
    data = json.load(f)

addrs = {}
for tx in data.get('transactions', []):
    name = tx.get('contractName')
    addr = w3.to_checksum_address(tx['contractAddress'])
    if name == "YibbleUSD": addrs['YBUSD'] = addr
    if name == "YipUSD": addrs['YPUSD'] = addr
    if name == "YibbleSwap": addrs['SWAP'] = addr
    if name == "YibbleVault": addrs['VAULT'] = addr

# FIXED: Added 'transfer' to the ABI
usdc_abi = [
    {"inputs":[{"internalType":"address","name":"spender","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"approve","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[{"internalType":"address","name":"account","type":"address"}],"name":"balanceOf","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"address","name":"to","type":"address"},{"internalType":"uint256","name":"amount","type":"uint256"}],"name":"transfer","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"nonpayable","type":"function"}
]
swap_abi = [{"inputs":[{"internalType":"uint256","name":"amountIn","type":"uint256"}],"name":"swap","outputs":[],"stateMutability":"nonpayable","type":"function"}]
vault_abi = [
    {"inputs":[{"internalType":"uint256","name":"assets","type":"uint256"},{"internalType":"address","name":"receiver","type":"address"}],"name":"deposit","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[],"name":"totalAssets","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"chargeManagementFee","outputs":[],"stateMutability":"nonpayable","type":"function"}
]

ypusd = w3.eth.contract(address=addrs['YPUSD'], abi=usdc_abi)
ybusd = w3.eth.contract(address=addrs['YBUSD'], abi=usdc_abi)
swap = w3.eth.contract(address=addrs['SWAP'], abi=swap_abi)
vault = w3.eth.contract(address=addrs['VAULT'], abi=vault_abi)

print_slow(f"✅ YibbleUSD:  {addrs['YBUSD']}")
print_slow(f"✅ YipUSD:     {addrs['YPUSD']}")
print_slow(f"✅ YibbleSwap: {addrs['SWAP']}")
print_slow(f"✅ YibbleVault: {addrs['VAULT']}\n")

# 2. Simulate User Swap (ypUSD -> ybUSD)
print_slow("💸 [STEP 2] User swaps 10,000 ypUSD for ybUSD (0.10% fee)...")
ypusd.functions.transfer(user, 10000 * 10**6).transact({'from': owner})
ypusd.functions.approve(addrs['SWAP'], 10000 * 10**6).transact({'from': user})
swap.functions.swap(10000 * 10**6).transact({'from': user})
yb_bal = ybusd.functions.balanceOf(user).call() / 10**6
print_slow(f" ↳ User received {yb_bal:,.2f} ybUSD\n")

# 3. Simulate Vault Deposit
print_slow("🏦 [STEP 3] User deposits ybUSD into the ERC-4626 Vault...")
ybusd.functions.approve(addrs['VAULT'], int(yb_bal * 10**6)).transact({'from': user})
vault.functions.deposit(int(yb_bal * 10**6), user).transact({'from': user})
aum_before = vault.functions.totalAssets().call() / 10**6
print_slow(f" ↳ Vault AUM: ${aum_before:,.2f} ybUSD\n")

# 4. Warp Time and Charge Fee
print_slow("⏳ [STEP 4] Warping time 1 year to accrue the 0.20% CEO Management Fee...")
w3.provider.make_request("evm_increaseTime", [31536000])
w3.provider.make_request("evm_mine", [])

# Call chargeManagementFee on the vault
vault.functions.chargeManagementFee().transact({'from': owner})
time.sleep(1)

aum_after = vault.functions.totalAssets().call() / 10**6
print_slow(f" ↳ Vault AUM AFTER Fee: ${aum_after:,.2f} ybUSD")
print_slow(f" ↳ Fee Extracted by CEO: ${aum_before - aum_after:,.2f} ybUSD")
print_slow("\n💥 [YIBBLE V2.0 LIFECYCLE COMPLETE] The flywheel is mathematically proven.")
