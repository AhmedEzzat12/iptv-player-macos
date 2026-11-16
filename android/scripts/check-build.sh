#!/bin/bash
# The Android counterpart of scripts/test.sh + swift build: unit tests (core on the JVM, Android modules) and a debug
# build of the TV app. Usage: android/scripts/check-build.sh [extra gradle args]
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ANDROID_DIR"
./gradlew --console=plain :core:test :data:testDebugUnitTest :player:testDebugUnitTest :app:assembleDebug "$@"
