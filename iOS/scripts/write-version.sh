#!/usr/bin/env bash
# Writes iOS/Config/Version.xcconfig (git-ignored) from the VERSION file and the commit count, so every Xcode build
# of the iPhone/iPad and Mac App Store apps carries the same version as the GitHub Mac app. Base.xcconfig includes it.
#   iOS/scripts/write-version.sh
set -euo pipefail
cd "$(dirname "$0")/.."
printf '// Written by iOS/scripts/write-version.sh from VERSION and the commit count. Do not edit.\nMARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' \
  "$(tr -d '[:space:]' < ../VERSION)" "$(git rev-list --count HEAD)" > Config/Version.xcconfig
