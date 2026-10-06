#!/usr/bin/env bash
# Installs (or removes) a login agent that re-installs Tuner on your iPhone/iPad every 5 days, so a free
# Personal Team install never reaches its 7-day expiry. The phone must be reachable then: plugged in, or on
# the same Wi-Fi with wireless pairing set up in Xcode's Devices window. Missed runs retry at the next login.
#   iOS/scripts/install-resign-agent.sh            # install / update
#   iOS/scripts/install-resign-agent.sh --remove   # uninstall
# Log: ~/Library/Logs/Tuner-iOS-resign.log
set -euo pipefail
LABEL="app.tuner.ios.resign"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/install-device.sh"
LOG="$HOME/Library/Logs/Tuner-iOS-resign.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>"$SCRIPT"</string></array>
  <key>StartInterval</key><integer>432000</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: runs $SCRIPT every 5 days (log: $LOG)."
echo "Run it now with: launchctl kickstart gui/$(id -u)/$LABEL"
