#!/usr/bin/env bash
# Builds Tuner.app (Command Line Tools only — no Xcode needed).
#   scripts/build-app.sh            # release build → build/Tuner.app
#   scripts/build-app.sh debug      # debug build
#   scripts/build-app.sh release --open
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
OPEN="${2:-}"

swift build -c "$CONFIG" --product Tuner
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(swift scripts/make-icon.swift "$PWD" | tail -1)"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

APP=build/Tuner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tuner" "$APP/Contents/MacOS/Tuner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature (no hardened runtime, so Homebrew's libmpv can be dlopen'ed at runtime).
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "$OPEN" == "--open" ]]; then open "$APP"; fi
