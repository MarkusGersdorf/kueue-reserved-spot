#!/usr/bin/env bash
# Live view. Run this in a second terminal while scripts/demo.sh drives.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
INTERVAL="${INTERVAL:-3}"
while true; do
  clear
  printf '%s  kueue reserved-spot demo — %s%s\n' "$C_DIM" "$(date '+%H:%M:%S')" "$C_RESET"
  "$REPO_ROOT/scripts/status.sh" 2>/dev/null || true
  sleep "$INTERVAL"
done
