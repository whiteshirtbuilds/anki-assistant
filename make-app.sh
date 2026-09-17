#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/Anki-Lernassistent.app"

cd "$PROJECT_DIR"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Die aktuelle Command-Line-Tools-Installation enthält mehrere SDKs. Der
# unversionierte SDK-Link kann nach einem Systemupdate kurzzeitig neuer als
# der Swift-Compiler sein; 26.5 ist mit dem installierten Compiler kompatibel.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
export CLANG_MODULE_CACHE_PATH=/tmp/anki-lernassistent-clang-cache

swift build
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "App/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -n "${ANKI_ASSISTANT_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ANKI_ASSISTANT_BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
fi
cp ".build/debug/AnkiLernassistent" "$APP_DIR/Contents/MacOS/AnkiLernassistent"
rm -rf "$APP_DIR/Contents/Resources/VoiceBridge"
cp -R "VoiceBridge" "$APP_DIR/Contents/Resources/VoiceBridge"
find "$APP_DIR/Contents/Resources/VoiceBridge" -type d -name '__pycache__' -prune -exec rm -rf {} +
chmod +x "$APP_DIR/Contents/MacOS/AnkiLernassistent"

# Eine vorhandene Apple-Entwicklersignatur ist wichtig für den Schlüsselbund:
# „Immer erlauben“ bleibt damit auch nach einem Neuaufbau der App gültig.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
    echo "Keine Apple-Entwicklersignatur gefunden; signiere lokal ad-hoc."
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
echo "Fertig: $APP_DIR"
