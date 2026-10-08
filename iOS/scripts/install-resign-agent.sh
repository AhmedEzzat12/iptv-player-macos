#!/usr/bin/env bash
# Installs (or removes) a login agent that keeps Tuner on your iPhone/iPad from reaching the 7-day expiry of a
# free Personal Team install: every 3 hours (and at login) it runs resign-if-due.sh, which re-installs once the
# last install is 4 days old. The phone must be reachable then: plugged in, or on the same Wi-Fi once paired
# (it can be locked). Until it succeeds it keeps trying; from day 5 it also posts a notification.
#   iOS/scripts/install-resign-agent.sh            # install / update
#   iOS/scripts/install-resign-agent.sh --remove   # uninstall
# Log: ~/Library/Logs/Tuner-iOS-resign.log
set -euo pipefail
LABEL="app.tuner.ios.resign"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/resign-if-due.sh"
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
  <array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>StartInterval</key><integer>10800</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL: runs $SCRIPT every 3 hours; it re-installs when the last install is 4+ days old."
echo "Log: $LOG. Re-install now: FORCE=1 $SCRIPT"
