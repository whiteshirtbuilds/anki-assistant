#!/bin/zsh
# Startet die lokale Bildanalyse für Anki im Hintergrund.
# Log und Prozess-ID bleiben im Projektordner, die Markdown-Dateien auf der externen Platte.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
LOG_FILE="$PROJECT_DIR/anki-image-indexer.log"
PID_FILE="$PROJECT_DIR/anki-image-indexer.pid"
DECK_QUERY="${1:-deck:\"FT 1\"}"

if [[ -f "$PID_FILE" ]] && kill -0 "$(<"$PID_FILE")" 2>/dev/null; then
  echo "Die Bildanalyse läuft bereits."
  exit 0
fi

nohup /usr/bin/python3 -u "$PROJECT_DIR/anki_image_indexer.py" --deck "$DECK_QUERY" --idle-seconds 300 >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "Bildanalyse läuft im Hintergrund. Neue Beschreibungen liegen auf der externen Festplatte unter LocalAI/anki-image-markdown/."
