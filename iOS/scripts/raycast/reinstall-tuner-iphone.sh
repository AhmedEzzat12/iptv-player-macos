#!/bin/bash

# Raycast Script Command: re-installs Tuner on your iPhone now (renews the free Personal Team's 7-day signing).
# Add this folder in Raycast → Settings → Extensions → Script Commands → Add Directories.
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Reinstall Tuner on iPhone
# @raycast.mode silent
#
# Optional parameters:
# @raycast.icon 📺
# @raycast.packageName Tuner
# @raycast.description Builds Tuner from the repo and installs it on your iPhone (plugged in or on the same Wi-Fi).

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/Tuner-iOS-resign.log"
osascript -e 'display notification "Building and installing… (a minute or two)" with title "Tuner for iPhone"' >/dev/null 2>&1
# Notifications report how it went (resign-if-due.sh); the log keeps the details.
if FORCE=1 "$SCRIPTS/resign-if-due.sh" >> "$LOG" 2>&1; then
  echo "Tuner reinstalled on your iPhone"
else
  echo "Tuner wasn't reinstalled — see ~/Library/Logs/Tuner-iOS-resign.log"
  exit 1
fi
