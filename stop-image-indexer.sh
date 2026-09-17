#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
PID_FILE="$PROJECT_DIR/anki-image-indexer.pid"
if [[ -f "$PID_FILE" ]]; then
  kill "$(<"$PID_FILE")" 2>/dev/null || true
  rm "$PID_FILE"
  echo "Bildanalyse gestoppt."
else
  echo "Die Bildanalyse läuft nicht."
fi
