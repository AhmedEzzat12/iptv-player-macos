#!/usr/bin/env bash
# Compiles the iPhone/iPad app (unsigned, generic iOS device) to check that shared changes didn't break it.
# Needs Xcode (with the iOS platform) and XcodeGen (brew install xcodegen). Used by scripts/release.sh.
#   iOS/scripts/check-build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate --quiet
xcodebuild -project TunerIOS.xcodeproj -scheme TunerIOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath ../.build/xcode-ios-check \
  CODE_SIGNING_ALLOWED=NO build -quiet
echo "iOS build OK"
