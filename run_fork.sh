#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Run the fork test. One command. No config needed if
#  FORK_RPC is already in your environment.
# ============================================================
set -uo pipefail
GRN=$'\e[32m'; RED=$'\e[31m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

cd "$HOME/yibble/contracts" || die "no project"

if [ -z "${FORK_RPC:-}" ]; then
  cat <<NEED_RPC

You need a Sepolia RPC URL. Free, 30 seconds:

  1. Go to https://dashboard.alchemy.com/signup
  2. Sign up (free tier, no card)
  3. Create App -> Chain: Ethereum Sepolia
  4. Copy the HTTPS URL, looks like:
       https://eth-sepolia.g.alchemy.com/v2/AbC123...
  5. Export it:
       export FORK_RPC="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
  6. Rerun this script: ~/yibble/run_fork.sh

Alternatives (if you don't want an account):
  export FORK_RPC="https://ethereum-sepolia-rpc.publicnode.com"
  export FORK_RPC="https://rpc.sepolia.org"     # rate-limited, may hang

NEED_RPC
  exit 1
fi

info "FORK_RPC: ${FORK_RPC:0:40}..."
info "USDC   : ${USDC_ADDRESS:-0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 (Sepolia)}"

info "running fork tests"
if forge test \
  --fork-url "$FORK_RPC" \
  --fork-retry-backoff 3000 \
  --match-contract YibbleVaultForkTest \
  -vvv; then
  ok "FORK TESTS PASSED"
  cat <<PASS

================================================================
  THE 4 FORK TESTS RAN AND PASSED
================================================================
  What this proves:
    - deposit 500 real USDC -> 500 shares (1:1)
    - redeem 500 shares -> 500 real USDC back
    - 0.20% fee accrues exactly 1 USDC per 500 USDC per year
    - vault works with Circle's 6-decimal USDC

  Next blocker (deploy to testnet):
    export ASSET_ADDRESS="0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
    export TREASURY_ADDRESS="0x$(head -c 20 /dev/urandom | xxd -p)"  # temp EOA
    export OWNER_ADDRESS="<your wallet>"
    forge script script/Deploy.s.sol \\
      --rpc-url \$FORK_RPC --broadcast

  Then update the fork test to attach to YOUR address (instead of
  deploying a fresh one) and rerun. That's the "deploy to testnet"
  checkbox.
================================================================
PASS
else
  die "fork tests failed - see output above"
fi
