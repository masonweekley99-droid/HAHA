#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Local deployment: YibbleUSD (your 6-decimal token) + YibbleVault
#  Runs entirely on Anvil 127.0.0.1:8545. Nothing external.
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

PROJECT="$HOME/yibble/contracts"
cd "$PROJECT" || die "cd $PROJECT failed"
info "project: $PROJECT"

# ---------- 1. verify Anvil ----------
info "checking Anvil on 127.0.0.1:8545"
CHAIN=$(curl -s -X POST http://127.0.0.1:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
if [ -z "$CHAIN" ]; then
  die "Anvil not reachable. Start it with: anvil &   (then rerun)"
fi
[ "$CHAIN" = "0x7a69" ] || die "chain $CHAIN is not Anvil (expected 0x7a69)"
ok "Anvil local running, chain id 31337"

# ---------- 2. write YibbleUSD (your own token) ----------
info "writing src/YibbleUSD.sol"
cat > src/YibbleUSD.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Local test stablecoin for the Yibble vault.
///         6 decimals to mirror USDC's interface. Owner-gated mint.
contract YibbleUSD is ERC20, Ownable {
    constructor(address initialOwner)
        ERC20("Yibble USD", "ybUSD")
        Ownable(initialOwner)
    {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
SOL_EOF
ok "YibbleUSD.sol written"

# ---------- 3. deploy script ----------
info "writing script/DeployLocal.s.sol"
cat > script/DeployLocal.s.sol <<'SOL_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YibbleUSD} from "../src/YibbleUSD.sol";
import {YibbleVault} from "../src/YibbleVault.sol";

contract DeployLocal is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        YibbleUSD usd = new YibbleUSD(deployer);
        YibbleVault vault = new YibbleVault(
            IERC20(address(usd)),
            deployer,   // treasury
            deployer    // owner
        );

        usd.mint(deployer, 1_000_000 * 10 ** 6);

        usd.approve(address(vault), 100_000 * 10 ** 6);
        vault.deposit(100_000 * 10 ** 6, deployer);

        vm.stopBroadcast();

        console.log("== deployment summary ==");
        console.log("Deployer    :", deployer);
        console.log("YibbleUSD   :", address(usd));
        console.log("YibbleVault :", address(vault));
        console.log("Vault assets:", vault.totalAssets());
        console.log("Vault shares:", vault.totalSupply());
    }
}
SOL_EOF
ok "DeployLocal.s.sol written"

# ---------- 4. build ----------
info "forge build"
forge build || die "build failed"
ok "build passed"

# ---------- 5. deploy ----------
# Anvil account 0 key - public, only valid on local Anvil
ANVIL_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
info "deploying with Anvil account 0 (0xf39F...)"
PRIVATE_KEY="$ANVIL_KEY" forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vv || die "deploy failed"
ok "deployment complete"

# ---------- 6. read back state via cast ----------
info "verifying deployed state"
RUN_JSON=$(ls broadcast/DeployLocal.s.sol/31337/run-latest.json 2>/dev/null)
if [ -n "$RUN_JSON" ]; then
  USD=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleUSD'][0])")
  VAULT=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleVault'][0])")
  ok "YibbleUSD   = $USD"
  ok "YibbleVault = $VAULT"
  echo
  info "cast checks:"
  cast call "$VAULT" "totalAssets()(uint256)" --rpc-url http://127.0.0.1:8545 || true
  cast call "$VAULT" "name()(string)" --rpc-url http://127.0.0.1:8545 || true
  cast call "$VAULT" "convertToAssets(uint256)(uint256)" 1000000 --rpc-url http://127.0.0.1:8545 || true
else
  warn "broadcast json not found - re-run with -vv to see addresses"
fi

cat <<DONE_EOF

================================================================
  LOCAL DEPLOYMENT COMPLETE
================================================================
  Chain       : Anvil 31337 (127.0.0.1:8545)
  Token       : YibbleUSD (ybUSD), 6 decimals, owner-mintable
  Vault       : YibbleVault (ERC-4626), asset = ybUSD
  Smoke test  : 100,000 ybUSD deposited -> 100,000 shares

  All local. No USDC, no faucet, no Circle, no Sepolia.
  These are YOUR contracts on YOUR chain.

  Inspect with cast:
    cast call <VAULT> "totalAssets()(uint256)" --rpc-url http://127.0.0.1:8545
    cast call <USD>   "balanceOf(address)(uint256)" <YOUR_ADDR> --rpc-url http://127.0.0.1:8545

  Full deployment record:
    broadcast/DeployLocal.s.sol/31337/run-latest.json

  Reset the chain to fresh state:
    kill %1
    anvil &
    ~/yibble/deploy_local.sh

  Next (optional):
    - Python script using web3.py to query the vault
    - Frontend dashboard
    - Deploy to testnet when you're ready
================================================================
DONE_EOF

ok "done"
