#!/bin/bash
# Creates (once) and boots the Google TV emulator "antenna-tv" (API 36, 1080p, 2 GB RAM like a low-end TV box).
# Usage: android/scripts/emulator.sh [--headless]. Prints the device serial when it has booted.
set -euo pipefail
source "$(dirname "$0")/env.sh"
AVD=antenna-tv
IMAGE="system-images;android-36;google-tv;arm64-v8a"
if ! avdmanager list avd -c 2>/dev/null | /usr/bin/grep -qx "$AVD"; then
  echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d tv_1080p >/dev/null
  printf 'hw.ramSize=2048\nhw.keyboard=yes\n' >> "$HOME/.android/avd/$AVD.avd/config.ini"
fi
ARGS=(-avd "$AVD" -no-snapshot-save -no-boot-anim)
[[ "${1:-}" == "--headless" ]] && ARGS+=(-no-window -no-audio)
emulator "${ARGS[@]}" >/dev/null 2>&1 &
echo "emulator pid $!" >&2
adb wait-for-device
until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do sleep 2; done
adb devices | /usr/bin/awk 'NR>1 && /emulator/ {print $1}'
