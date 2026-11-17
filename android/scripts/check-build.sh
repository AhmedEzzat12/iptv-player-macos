#!/bin/bash
# The Android counterpart of scripts/test.sh + swift build: unit tests (core on the JVM, Android modules) and a debug
# build of the TV app. Usage: android/scripts/check-build.sh [extra gradle args]
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$ANDROID_DIR"
./gradlew --console=plain :core:test :core:animalsnifferMain :data:testDebugUnitTest :player:testDebugUnitTest :app:assembleDebug "$@"
# JUnit silently skips @Test methods that return a value: make sure every written test ran.
python3 -I scripts/check-tests-ran.py core data player
