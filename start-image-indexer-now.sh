#!/bin/zsh
# Startet die Bildanalyse sofort. Sie läuft unabhängig von Stromversorgung und Eingabe.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
LOG_FILE="$PROJECT_DIR/anki-image-indexer.log"
PID_FILE="$PROJECT_DIR/anki-image-indexer.pid"
DECK_QUERY="${1:-deck:\"FT 1\"}"

if [[ -f "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" 2>/dev/null; then
  echo "Die Bildanalyse läuft bereits."
  exit 0
fi

nohup /usr/bin/python3 -u "$PROJECT_DIR/anki_image_indexer.py" --deck "$DECK_QUERY" --always >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "Bildanalyse startet sofort. Stoppen mit ./stop-image-indexer.sh"
