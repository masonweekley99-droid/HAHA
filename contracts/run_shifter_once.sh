#!/data/data/com.termux/files/usr/bin/bash
cd "/data/data/com.termux/files/home/yibble/contracts" || exit 1
SHIFT_ENABLED=1 BPS_TO_AUM=7500 SHIFT_THRESHOLD=1000000 \
  python3 yield_shifter.py >> "$HOME/yibble/shifter.log" 2>&1
