#!/usr/bin/env bash
# Run by the login agent from install-resign-agent.sh every few hours: re-installs Tuner on the iPhone/iPad once
# the last install is 4 days old (free Personal Team installs stop opening after 7), so a locked, asleep or
# away phone just means another try a few hours later. Builds the checkout as it is, so it waits while the
# sources have uncommitted changes. Posts a notification when the install is close to expiring.
#   iOS/scripts/resign-if-due.sh           # what the agent runs
#   FORCE=1 iOS/scripts/resign-if-due.sh   # re-install now
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/../.."
STAMP="$HOME/Library/Application Support/app.tuner.ios.resign/last-install"
LOCK="$HOME/Library/Application Support/app.tuner.ios.resign/running"

notify() { osascript -e "display notification \"$1\" with title \"Tuner for iPhone\"" >/dev/null 2>&1 || true; }

age_days=99
if [[ -f "$STAMP" ]]; then
  age_days=$(( ($(date +%s) - $(stat -f %m "$STAMP")) / 86400 ))
fi
if [[ "${FORCE:-}" != "1" && $age_days -lt 4 ]]; then
  exit 0
fi
echo "$(date): last install $age_days day(s) ago, re-installing"

mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A run that died leaves the lock behind: ignore it after 2 hours.
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +120)" ]]; then rmdir "$LOCK"; mkdir "$LOCK"; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if [[ -n "$(git status --porcelain -- Sources iOS Package.swift)" ]]; then
  echo "Sources have uncommitted changes; trying again later."
  [[ $age_days -ge 6 ]] && notify "Expires soon. Commit or stash the changes in the Tuner repo so it can re-install."
  exit 0
fi

if iOS/scripts/install-device.sh; then
  echo "$(date): done"
else
  echo "$(date): failed; trying again later"
  [[ $age_days -ge 5 ]] && notify "Couldn't re-install (age $age_days days). Put the iPhone on the Mac's Wi-Fi or plug it in."
  exit 1
fi
