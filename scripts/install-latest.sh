#!/bin/bash
# Installs (or reinstalls) the latest Tuner release.
#
#   curl -fsSL https://raw.githubusercontent.com/AhmedEzzat12/iptv-player-macos/main/scripts/install-latest.sh | bash
#
# The app isn't notarized by Apple, so a copy downloaded in a browser gets the quarantine flag and macOS
# refuses to open it ("Apple could not verify…"). curl doesn't set that flag, and this script clears it
# anyway, so the app opens straight away. Later updates arrive in-app (Sparkle) and aren't quarantined either.
#
# Optional: INSTALL_DIR (default /Applications, falls back to ~/Applications), NO_LAUNCH=1.
set -euo pipefail

REPO="AhmedEzzat12/iptv-player-macos"
APP="Tuner.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
if [[ ! -w "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading the latest Tuner…"
curl -fsSL -o "$WORK/app.zip" "https://github.com/$REPO/releases/latest/download/Tuner.zip"
ditto -x -k "$WORK/app.zip" "$WORK"
xattr -dr com.apple.quarantine "$WORK/$APP" 2>/dev/null || true

# Quit the copy being replaced (only that one) and wait for it to exit, so the new one really launches.
BINARY="$INSTALL_DIR/$APP/Contents/MacOS/Tuner"
if pgrep -f "^$BINARY" >/dev/null; then
  pkill -f "^$BINARY" || true
  for _ in $(seq 50); do pgrep -f "^$BINARY" >/dev/null || break; sleep 0.1; done
fi

# Copy next to the old app first and swap only once the copy succeeded.
STAGED="$INSTALL_DIR/.$APP.new"
rm -rf "$STAGED"
ditto "$WORK/$APP" "$STAGED"
rm -rf "${INSTALL_DIR:?}/$APP"
mv "$STAGED" "$INSTALL_DIR/$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_DIR/$APP/Contents/Info.plist")"
echo "Installed Tuner $VERSION in $INSTALL_DIR"

if ! command -v mpv >/dev/null && [[ ! -e /opt/homebrew/lib/libmpv.dylib && ! -e /usr/local/lib/libmpv.dylib ]]; then
  echo "Optional: 'brew install mpv' plays MKV and raw MPEG-TS streams; 'brew install ffmpeg' enables recordings."
fi

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  open "$INSTALL_DIR/$APP"
fi
