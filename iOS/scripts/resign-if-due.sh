#!/usr/bin/env bash
# Run by the login agent from install-resign-agent.sh every few hours: re-installs Tuner on the iPhone/iPad once
# the last install is 4 days old (free Personal Team installs stop opening after 7), so a locked, asleep or
# away phone just means another try a few hours later. Builds the checkout as it is, so it waits while the
# sources have uncommitted changes. Posts a notification after each re-install, and when the install is close to
# expiring.
#   iOS/scripts/resign-if-due.sh           # what the agent runs
#   FORCE=1 iOS/scripts/resign-if-due.sh   # re-install now
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# BSD date/stat on purpose (Homebrew's GNU coreutils may come first on an interactive PATH).
cd "$(dirname "$0")/../.."
STAMP="$HOME/Library/Application Support/app.tuner.ios.resign/last-install"
LOCK="$HOME/Library/Application Support/app.tuner.ios.resign/running"

notify() { osascript -e "display notification \"$1\" with title \"Tuner for iPhone\"" >/dev/null 2>&1 || true; }
# A re-install asked for by hand (FORCE=1, e.g. from Raycast) reports every outcome, not only near expiry.
forced() { [[ "${FORCE:-}" == "1" ]]; }

age_days=99
if [[ -f "$STAMP" ]]; then
  age_days=$(( ($(/bin/date +%s) - $(/usr/bin/stat -f %m "$STAMP")) / 86400 ))
fi
if [[ "${FORCE:-}" != "1" && $age_days -lt 4 ]]; then
  exit 0
fi
echo "$(/bin/date): last install $age_days day(s) ago, re-installing"

mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A run that died leaves the lock behind: ignore it after 2 hours.
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +120)" ]]; then
    rmdir "$LOCK"; mkdir "$LOCK"
  else
    forced && notify "A re-install is already running."
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if [[ -n "$(git status --porcelain -- Sources iOS Package.swift)" ]]; then
  echo "Sources have uncommitted changes; trying again later."
  if forced; then
    notify "Didn't re-install: the Tuner repo has uncommitted changes. Commit or stash them, then try again."
    exit 1
  fi
  [[ $age_days -ge 6 ]] && notify "Expires soon. Commit or stash the changes in the Tuner repo so it can re-install."
  exit 0
fi

if iOS/scripts/install-device.sh; then
  echo "$(/bin/date): done"
  notify "Re-installed Tuner $(tr -d '[:space:]' < VERSION) on your iPhone. Good until $(/bin/date -v+7d '+%a %-d %b')."
else
  echo "$(/bin/date): failed; trying again later"
  if forced || [[ $age_days -ge 5 ]]; then
    notify "Couldn't re-install. Put the iPhone on the Mac's Wi-Fi (unlocked once since it started) or plug it in."
  fi
  exit 1
fi
