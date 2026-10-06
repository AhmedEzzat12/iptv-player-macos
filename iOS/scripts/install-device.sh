#!/usr/bin/env bash
# Builds Tuner (Release) for a connected iPhone/iPad and installs it, keeping the app's data.
#   iOS/scripts/install-device.sh            # first connected iPhone/iPad
#   iOS/scripts/install-device.sh <udid>     # a specific device (xcrun devicectl list devices)
# Signing comes from iOS/Config/Local.xcconfig (copy Local.xcconfig.example). With a free Personal Team the
# install expires after 7 days: run this again before then (iOS/scripts/install-resign-agent.sh automates it).
# The device needs Developer Mode on (Settings › Privacy & Security) and must trust this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Config/Local.xcconfig ]]; then
  echo "Missing iOS/Config/Local.xcconfig: copy Config/Local.xcconfig.example and set your team ID." >&2
  exit 1
fi

UDID="${1:-}"
if [[ -z "$UDID" ]]; then
  LIST="$(mktemp)"
  trap 'rm -f "$LIST"' EXIT
  xcrun devicectl list devices --json-output "$LIST" >/dev/null
  UDID="$(python3 - "$LIST" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    # Real devices only: devicectl also lists simulators (reality "simulated").
    if hw.get("platform") == "iOS" and hw.get("deviceType") in ("iPhone", "iPad") \
            and hw.get("reality") != "simulated" \
            and conn.get("pairingState") == "paired" and conn.get("tunnelState") != "unavailable":
        print(hw["udid"])
        break
PY
)"
fi
if [[ -z "$UDID" ]]; then
  echo "No paired iPhone/iPad is reachable. Connect it with a cable, unlock it and tap Trust." >&2
  exit 1
fi
echo "Installing on $UDID"

xcodegen generate --quiet
DERIVED="../.build/xcode-device"
# Same version numbers as the Mac build (scripts/build-app.sh): VERSION file + commit count.
VERSION="$(tr -d '[:space:]' < ../VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project TunerIOS.xcodeproj -scheme TunerIOS -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  build -quiet
xcrun devicectl device install app --device "$UDID" "$DERIVED/Build/Products/Release-iphoneos/Tuner.app"
echo "Installed. With a free Personal Team, run this again within 7 days."
