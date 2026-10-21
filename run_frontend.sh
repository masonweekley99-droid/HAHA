#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  Yibble Vault frontend - single HTML, ethers.js from CDN
#  - Reads vault address from broadcast JSON, bakes into page
#  - Serves on 127.0.0.1:8080 via python http.server
#  - Auto-refreshes every 5s
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
mkdir -p frontend || die "cannot mkdir frontend"

# ---------- 1. extract addresses ----------
RUN_JSON="broadcast/DeployLocal.s.sol/31337/run-latest.json"
[ -f "$RUN_JSON" ] || die "no $RUN_JSON - deploy first"
VAULT=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleVault'][0])")
USD=$(python3 -c "import json;d=json.load(open('$RUN_JSON'));print([t['contractAddress'] for t in d['transactions'] if t.get('contractName')=='YibbleUSD'][0])")
ok "YibbleVault = $VAULT"
ok "YibbleUSD   = $USD"

# ---------- 2. write index.html (templated with addresses) ----------
info "writing frontend/index.html"
cat > frontend/index.html <<HTML_EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Yibble Vault</title>
<script src="https://cdn.jsdelivr.net/npm/ethers@6.13.4/dist/ethers.umd.min.js"></script>
<style>
  :root {
    --bg:      #0a0e17;
    --panel:   #131822;
    --panel2:  #1a2030;
    --border:  #253048;
    --text:    #e4ebf5;
    --muted:   #7a8699;
    --accent:  #4ade80;
    --accent2: #60a5fa;
    --warn:    #fbbf24;
    --err:     #ef4444;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 24px 16px;
    line-height: 1.4;
  }
  .container { max-width: 960px; margin: 0 auto; }
  header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 24px; padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
  }
  h1 { font-size: 22px; font-weight: 600; letter-spacing: 0.02em; }
  h1 .crown { color: var(--warn); }
  .status {
    font-size: 12px; padding: 6px 12px; border-radius: 999px;
    background: var(--panel2); border: 1px solid var(--border);
    display: inline-flex; align-items: center; gap: 6px;
  }
  .dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--accent); box-shadow: 0 0 8px var(--accent);
  }
  .dot.err { background: var(--err); box-shadow: 0 0 8px var(--err); }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 12px;
    margin-bottom: 20px;
  }
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 16px;
  }
  .card .label {
    font-size: 11px; color: var(--muted);
    text-transform: uppercase; letter-spacing: 0.08em;
    margin-bottom: 6px;
  }
  .card .value {
    font-size: 22px; font-weight: 600;
    font-variant-numeric: tabular-nums;
    word-break: break-all;
  }
  .card .value.big { font-size: 28px; color: var(--accent2); }
  .card .sub {
    font-size: 11px; color: var(--muted); margin-top: 4px;
  }
  .card.featured { border-color: var(--accent2); }
  .card.fee { border-color: var(--warn); }
  .card.fee.ready { border-color: var(--accent); }
  .progress {
    height: 6px; background: var(--panel2);
    border-radius: 3px; overflow: hidden; margin-top: 10px;
  }
  .progress .bar {
    height: 100%;
    background: linear-gradient(90deg, var(--accent2), var(--accent));
    transition: width 0.3s ease;
  }
  .row {
    display: flex; justify-content: space-between; align-items: center;
    padding: 12px 0; border-bottom: 1px solid var(--border);
    font-size: 13px;
  }
  .row:last-child { border-bottom: none; }
  .row .k { color: var(--muted); }
  .row .v { font-variant-numeric: tabular-nums; }
  .addr {
    font-family: ui-monospace, 'SF Mono', Menlo, monospace;
    font-size: 11px; color: var(--muted); word-break: break-all;
  }
  footer {
    margin-top: 24px; padding-top: 16px;
    border-top: 1px solid var(--border);
    font-size: 11px; color: var(--muted);
    text-align: center;
  }
  .err-banner {
    background: rgba(239, 68, 68, 0.1);
    border: 1px solid var(--err);
    border-radius: 8px; padding: 12px 16px;
    margin-bottom: 16px; font-size: 13px;
    display: none;
  }
  .err-banner.show { display: block; }
</style>
</head>
<body>
<div class="container">

  <header>
    <h1><span class="crown">👑</span> Yibble Vault</h1>
    <div class="status">
      <span class="dot" id="dot"></span>
      <span id="status-text">connecting...</span>
    </div>
  </header>

  <div class="err-banner" id="err-banner"></div>

  <div class="grid">
    <div class="card featured">
      <div class="label">Total Assets (AUM)</div>
      <div class="value big" id="assets">-</div>
      <div class="sub" id="assets-sub">ybUSD</div>
    </div>
    <div class="card">
      <div class="label">Total Shares</div>
      <div class="value" id="supply">-</div>
      <div class="sub">YIB</div>
    </div>
    <div class="card">
      <div class="label">Share Price</div>
      <div class="value" id="price">-</div>
      <div class="sub" id="price-sub">ybUSD per 1 YIB</div>
    </div>
    <div class="card">
      <div class="label">Treasury</div>
      <div class="value" id="treasury">-</div>
      <div class="sub">ybUSD (CEO account)</div>
    </div>
  </div>

  <div class="card fee" id="fee-card" style="margin-bottom: 20px;">
    <div class="label">Pending Management Fee (0.20% annual)</div>
    <div class="value" id="pending">-</div>
    <div class="sub" id="pending-sub">ybUSD</div>
    <div class="progress"><div class="bar" id="fee-bar" style="width: 0%"></div></div>
    <div class="sub" id="countdown" style="margin-top: 8px;">-</div>
  </div>

  <div class="card">
    <div class="row"><span class="k">Block</span><span class="v" id="block">-</span></div>
    <div class="row"><span class="k">Chain time</span><span class="v" id="chain-time">-</span></div>
    <div class="row"><span class="k">Last accrual</span><span class="v" id="last">-</span></div>
    <div class="row"><span class="k">Vault contract</span><span class="v addr">${VAULT}</span></div>
    <div class="row"><span class="k">Asset token</span><span class="v addr">${USD}</span></div>
  </div>

  <footer>
    Yibble Vault · local Anvil · auto-refresh 5s · <span id="updated">-</span>
  </footer>
</div>

<script>
const CONFIG = {
  RPC_URL:      "http://127.0.0.1:8545",
  VAULT:        "${VAULT}",
  ASSET:        "${USD}",
  DECIMALS:     6,
  REFRESH_MS:   5000,
  MIN_FEE_WEI:  10000,
  YEAR_SEC:     365 * 24 * 3600,
};

const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function pendingFee() view returns (uint256)",
  "function lastAccrual() view returns (uint256)",
  "function treasury() view returns (address)",
  "function asset() view returns (address)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function owner() view returns (address)",
];
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)"];

let provider, vault, assetContract, treasuryAddr;
const $ = (id) => document.getElementById(id);

function fmt(wei, decimals = CONFIG.DECIMALS, dp = 4) {
  const n = Number(wei) / Math.pow(10, decimals);
  return n.toLocaleString("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });
}

function fmtInt(n) {
  return Number(n).toLocaleString("en-US");
}

function humanizeSecs(s) {
  if (s === null || s === undefined) return "n/a";
  if (s <= 0) return "READY TO ACCRUE";
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60);
  if (d > 0) return d + "d " + String(h).padStart(2, "0") + "h";
  if (h > 0) return h + "h " + String(m).padStart(2, "0") + "m";
  if (m > 0) return m + "m " + String(sec).padStart(2, "0") + "s";
  return sec + "s";
}

function setStatus(kind, text) {
  $("dot").className = "dot" + (kind === "err" ? " err" : "");
  $("status-text").textContent = text;
}

function showError(msg) {
  const b = $("err-banner");
  b.classList.add("show");
  b.textContent = "⚠ " + msg;
  setStatus("err", "error");
}

function clearError() {
  $("err-banner").classList.remove("show");
}

async function init() {
  try {
    provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
    const net = await provider.getNetwork();
    if (Number(net.chainId) !== 31337) {
      throw new Error("Wrong chain: " + net.chainId + " (expected 31337)");
    }
    vault = new ethers.Contract(CONFIG.VAULT, VAULT_ABI, provider);
    treasuryAddr = await vault.treasury();
    assetContract = new ethers.Contract(CONFIG.ASSET, ERC20_ABI, provider);
    setStatus("ok", "connected · chain 31337");
    clearError();
    await refresh();
  } catch (e) {
    showError(e.message || String(e));
    console.error(e);
  }
}

async function refresh() {
  try {
    const [assets, supply, pending, last, blockNum, treasuryBal, priceWei] =
      await Promise.all([
        vault.totalAssets(),
        vault.totalSupply(),
        vault.pendingFee(),
        vault.lastAccrual(),
        provider.getBlockNumber(),
        assetContract.balanceOf(treasuryAddr),
        vault.convertToAssets(10n ** BigInt(CONFIG.DECIMALS)),
      ]);

    const block = await provider.getBlock(blockNum);
    const now = block.timestamp;

    $("assets").textContent = fmt(assets);
    $("supply").textContent = fmt(supply);
    $("price").textContent = fmt(priceWei);
    $("treasury").textContent = fmt(treasuryBal);

    $("pending").textContent = fmt(pending);
    $("pending-sub").textContent = "ybUSD · threshold " + fmt(CONFIG.MIN_FEE_WEI, 6, 4);

    // annual fee rate based on current AUM
    const annualFee = (assets * 20n) / 10000n;
    const annualFeeNum = Number(annualFee);

    // countdown to next accrual
    let secsToMin = null;
    if (Number(pending) >= CONFIG.MIN_FEE_WEI) {
      secsToMin = 0;
    } else if (annualFeeNum > 0) {
      secsToMin = Math.floor(
        ((CONFIG.MIN_FEE_WEI - Number(pending)) * CONFIG.YEAR_SEC) / annualFeeNum
      );
    }

    // progress bar
    const pct = Math.min(100, (Number(pending) / CONFIG.MIN_FEE_WEI) * 100);
    $("fee-bar").style.width = pct.toFixed(1) + "%";

    const feeCard = $("fee-card");
    if (Number(pending) >= CONFIG.MIN_FEE_WEI) {
      feeCard.classList.add("ready");
      $("countdown").textContent = "● READY NOW — keeper should accrue";
      $("countdown").style.color = "var(--accent)";
    } else {
      feeCard.classList.remove("ready");
      $("countdown").textContent =
        "Next accrual in " + humanizeSecs(secsToMin) +
        " · rate " + fmt(annualFee) + " ybUSD/yr";
      $("countdown").style.color = "var(--muted)";
    }

    $("block").textContent = fmtInt(blockNum);
    $("chain-time").textContent = now + " (" + new Date(now * 1000).toISOString() + ")";
    $("last").textContent = last + " (" + (now - Number(last)) + "s ago)";
    $("updated").textContent = "updated " + new Date().toLocaleTimeString();

    if (Number(pending) >= CONFIG.MIN_FEE_WEI) {
      setStatus("ok", "fees ready");
    } else {
      setStatus("ok", "accruing");
    }
    clearError();
  } catch (e) {
    showError(e.message || String(e));
    console.error(e);
  }
}

init();
setInterval(refresh, CONFIG.REFRESH_MS);
</script>
</body>
</html>
HTML_EOF
ok "index.html written ($(wc -c < frontend/index.html) bytes)"

# ---------- 3. serve ----------
info "starting http server on 127.0.0.1:8080"
cd frontend || die "cd frontend failed"

cat <<DONE_EOF

================================================================
  FRONTEND READY
================================================================
  URL        : http://127.0.0.1:8080
  Served from: $(pwd)
  Vault      : $VAULT
  Asset      : $USD
  Chain      : Anvil 31337

  Starting server now. Open the URL in a browser:
    - Same device:    http://127.0.0.1:8080
    - Another device: http://<phone-IP>:8080  (needs --bind 0.0.0.0)

  To stop: Ctrl+C in this terminal.

  If the page loads but shows "connecting..." forever:
    1. Check Anvil is still running (this terminal will tell you)
    2. Check browser console for CORS errors
    3. If CORS: restart Anvil with:
         anvil --allow-origin '*'

  If you see "Wrong chain: ...":
    browser is connected but not to Anvil. Check CONFIG.RPC_URL
    inside frontend/index.html matches your Anvil.

  What it shows:
    - AUM (totalAssets) in ybUSD, live
    - Total shares (YIB)
    - Share price - the number that matters (currently 0.998)
    - Treasury balance (CEO's cut, accumulating)
    - Pending fee + progress bar toward MIN_FEE_WEI
    - Countdown to next viable accrual
    - Status (accruing / fees ready / error)

  How to see it change:
    - Terminal A: this one (http server running)
    - Terminal B: python3 keeper.py --demo    <- warps +1yr, accrues
    - Watch the browser: AUM drops, treasury rises, pending resets

  Screenshot tip: rotate phone to landscape for the 4-card grid to
  fill the width nicely.

================================================================
DONE_EOF

python3 -m http.server 8080 --bind 127.0.0.1
