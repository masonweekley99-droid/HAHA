#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
cd "$HOME/yibble/contracts" || exit 1

# Replace the misleading summary with honest economics
python3 - <<'PY'
from pathlib import Path
p = Path("swap_demo.py")
s = p.read_text()

old = '''print("=" * 60)
print("FULL FLOW COMPLETE")
print("=" * 60)
print(f"  ypUSD -> swap -> ybUSD -> deposit -> YIB")
print(f"  {f(yp_amt):,.0f} ypUSD in -> {f(yib_bal):,.2f} YIB out")
lost = f(yp_amt) - f(yib_bal)
print(f"  Round-trip loss: {lost:,.4f}  ({100 * lost / f(yp_amt):.3f}%)")
print(f"  (that loss is the 0.10% swap fee, kept as ypUSD in treasury)")
print("=" * 60)'''

new = '''# Compute honest economics: what would alice get back if she redeemed NOW?
yb_redeemed = vault.functions.convertToAssets(yib_bal).call()
yp_in  = f(yp_amt)
yb_mid = f(yb_after)        # what she got from swap
yb_out = f(yb_redeemed)     # what she'd get from vault if redeemed now
real_loss = yp_in - yb_out

print("=" * 60)
print("FULL FLOW COMPLETE")
print("=" * 60)
print(f"  ypUSD -> swap -> ybUSD -> deposit -> YIB")
print(f"    in     : {yp_in:,.2f} ypUSD")
print(f"    swapped: {yb_mid:,.2f} ybUSD   (lost {yp_in - yb_mid:,.4f} to 0.10% fee)")
print(f"    shares : {f(yib_bal):,.2f} YIB     (at {f(vault.functions.convertToAssets(UNIT).call()):.4f} ybUSD/YIB)")
print(f"    redeem : {yb_out:,.2f} ybUSD    (what she'd get back if she exits now)")
print()
print(f"  Real round-trip cost: {real_loss:,.4f} ybUSD  ({100*real_loss/yp_in:.3f}%)")
print(f"  That cost = 0.10% swap fee. The vault itself does not")
print(f"  charge for deposit/redeem; the 0.20% annual fee accrues")
print(f"  over time, not per transaction.")
print("=" * 60)'''

if old not in s:
    raise SystemExit("anchor not found")
p.write_text(s.replace(old, new))
print("patched swap_demo.py")
PY
