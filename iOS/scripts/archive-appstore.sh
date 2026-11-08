#!/usr/bin/env bash
# Builds the App Store version of the iPhone/iPad app (or, with PLATFORM=mac, the Mac App Store app) and, with
# UPLOAD=1, sends it to App Store Connect.
#   iOS/scripts/archive-appstore.sh                       # iPhone/iPad: archive + export build/ios/export/Tuner.ipa
#   UPLOAD=1 iOS/scripts/archive-appstore.sh              # iPhone/iPad: archive + upload (TestFlight after processing)
#   PLATFORM=mac UPLOAD=1 iOS/scripts/archive-appstore.sh # Mac: archive + upload (export: build/mac-store/export/Tuner.pkg)
# Needs a paid team: DEVELOPMENT_TEAM in iOS/Config/Local.xcconfig. Both apps use bundle ID app.tuner.player (one
# product with Universal Purchase; TUNER_BUNDLE_ID overrides it). Signing uses the Apple ID in Xcode → Settings → Accounts, or an App Store Connect API key:
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/…/AuthKey_….p8
# Version: the VERSION file; build number: the commit count (must be higher than every earlier upload).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "Missing iOS/Config/Local.xcconfig: copy Config/Local.xcconfig.example and set your paid team ID." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "The working tree has uncommitted changes: commit first, so the build number matches a commit." >&2
  exit 1
fi

BUNDLE_ID="${TUNER_BUNDLE_ID:-app.tuner.player}"
VERSION="$(tr -d '[:space:]' < ../VERSION)"
BUILD="$(git rev-list --count HEAD)"
if [[ "${PLATFORM:-ios}" == mac ]]; then
  SCHEME=TunerMac; DEST="generic/platform=macOS"; OUT="../build/mac-store"; PRODUCT="Tuner.pkg"
else
  SCHEME=TunerIOS; DEST="generic/platform=iOS"; OUT="../build/ios"; PRODUCT="Tuner.ipa"
fi
ARCHIVE="$OUT/Tuner.xcarchive"
AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

# Xcode writes MPVKit into the repo's Package.resolved (the Mac build doesn't use it): put it back afterwards.
RESOLVED_BACKUP="$(mktemp)"
EXPORT_OPTIONS="$(mktemp).plist"
cp ../Package.resolved "$RESOLVED_BACKUP"
trap 'cp "$RESOLVED_BACKUP" ../Package.resolved; rm -f "$RESOLVED_BACKUP" "$EXPORT_OPTIONS"' EXIT

xcodegen generate --quiet
rm -rf "$ARCHIVE" "$OUT/export"
echo "Archiving $SCHEME $VERSION ($BUILD) as $BUNDLE_ID"
xcodebuild -project TunerIOS.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination "$DEST" -archivePath "$ARCHIVE" -derivedDataPath "../.build/xcode-archive-$SCHEME" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  TUNER_BUNDLE_ID="$BUNDLE_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive -quiet

DESTINATION=export
[[ "${UPLOAD:-0}" == 1 ]] && DESTINATION=upload
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

if [[ "$DESTINATION" == upload ]]; then
  echo "Uploaded Tuner $VERSION ($BUILD). It appears in App Store Connect → TestFlight after processing (10–30 min)."
else
  echo "Exported $OUT/export/$PRODUCT. Upload with UPLOAD=1, or drag it into Apple's Transporter app."
fi
