#!/usr/bin/env bash
# Builds Tuner.app (Command Line Tools only — no Xcode needed).
#   scripts/build-app.sh            # release build → build/Tuner.app
#   scripts/build-app.sh debug      # debug build
#   scripts/build-app.sh release --open
# Optional env: SPARKLE_PUBLIC_KEY turns on automatic updates (scripts/release.sh sets it; local builds never
# self-update), BUILD_NUMBER overrides the build number, BUILD_DIR puts the app somewhere other than build/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
OPEN="${2:-}"

# Source paths baked into assertion messages become repo-relative (release binaries are published).
BUILD_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
swift build -c "$CONFIG" --product Tuner "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${BUILD_FLAGS[@]}" --show-bin-path)"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(swift scripts/make-icon.swift "$PWD" | tail -1)"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

APP="${BUILD_DIR:-build}/Tuner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tuner" "$APP/Contents/MacOS/Tuner"
if [[ "$CONFIG" == "release" ]]; then
  # Drop debug symbols: they embed absolute build paths (your home folder and checkout location).
  strip -S "$APP/Contents/MacOS/Tuner"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version: CFBundleShortVersionString from VERSION, CFBundleVersion = commit count (always increases).
VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must look like 1.2.3 (or 1.2.3-beta.1), got '$VERSION'" >&2
  exit 1
fi
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || true)}"
BUILD="${BUILD:-1}"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

# Embed Sparkle (the binary's rpath points at Contents/Frameworks).
SPARKLE_FRAMEWORK="$(find "$BIN_DIR" -maxdepth 2 -name Sparkle.framework -type d | head -1)"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# Ad-hoc signature (no hardened runtime, so Homebrew's libmpv can be dlopen'ed at runtime).
# --deep also signs Sparkle's helpers (Autoupdate, Updater.app, XPC services) with the same identity.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP (version $VERSION, build $BUILD)"

if [[ "$OPEN" == "--open" ]]; then open "$APP"; fi
