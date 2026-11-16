#!/usr/bin/env bash
# Runs the TunerCore test suite. With only the Command Line Tools installed, the Swift Testing
# macro plugin lives in a subdirectory the compiler doesn't search by default.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
EXTRA=()
if [[ -d "$PLUGIN_DIR" ]]; then
  EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi

# Under Xcode the plugin is found automatically and EXTRA stays empty; the ${…+…} form keeps
# `set -u` in older bash from treating the empty array as unbound.
swift test ${EXTRA[@]+"${EXTRA[@]}"} "$@"

# Android parity: commits need an "Android:" trailer, checked by scripts/hooks/commit-msg once it's enabled.
if [[ "$(git config core.hooksPath 2>/dev/null)" != "scripts/hooks" ]]; then
  echo "note: the Android parity hook isn't enabled in this clone: git config core.hooksPath scripts/hooks" >&2
fi
