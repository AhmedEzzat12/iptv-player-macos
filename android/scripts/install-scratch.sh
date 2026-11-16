#!/bin/bash
# Builds the "scratch" variant (app.antenna.player.scratch) and installs + launches it on one device.
# Never installs over the owner's own copy. Usage: android/scripts/install-scratch.sh <serial>
set -euo pipefail
source "$(dirname "$0")/env.sh"
SERIAL="${1:?usage: install-scratch.sh <adb serial>}"
cd "$ANDROID_DIR"
./gradlew --console=plain :app:assembleScratch
adb -s "$SERIAL" install -r app/build/outputs/apk/scratch/app-scratch.apk
adb -s "$SERIAL" shell monkey -p app.antenna.player.scratch -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null
