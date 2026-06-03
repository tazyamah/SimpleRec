#!/bin/bash
# Relaunch the deployed canonical app WITHOUT rebuilding.
set -euo pipefail
DEST="/Applications/SimpleRec.app"
[[ -d "$DEST" ]] || { echo "$DEST not found. Run ./build.sh first." >&2; exit 1; }
pkill -x SimpleRec 2>/dev/null || true
sleep 1
open "$DEST"
