#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
WRAPPER="$HOME/yibble/contracts/run_shifter_once.sh"
[ -x "$WRAPPER" ] || { echo "wrapper missing"; exit 1; }

termux-job-scheduler --cancel-all 2>/dev/null || true

# Try in order of most features → least, stop at first that works
if termux-job-scheduler -s "$WRAPPER" --period-ms 900000 --persisted true --network 2>/dev/null; then
  echo "[ OK ] scheduled (persisted + network)"
elif termux-job-scheduler -s "$WRAPPER" --period-ms 900000 --persisted 2>/dev/null; then
  echo "[ OK ] scheduled (persisted only)"
elif termux-job-scheduler -s "$WRAPPER" --period-ms 900000 2>/dev/null; then
  echo "[ OK ] scheduled (basic, no reboot survival)"
else
  echo "[FAIL] scheduler rejects all flag combos"
  termux-job-scheduler --help | head -40
  exit 1
fi
echo
echo "Verify: termux-job-scheduler --list"
