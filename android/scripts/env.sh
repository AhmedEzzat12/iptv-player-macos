#!/bin/bash
# Sourced by the other android/scripts. Uses the latest stable JDK by its SDKMAN version path (never
# candidates/java/current, which is JDK 8 on the maintainer's Mac). Override with TUNER_JAVA_HOME / ANDROID_HOME.
SDKMAN_JAVA="/opt/homebrew/opt/sdkman-cli/libexec/candidates/java"
export JAVA_HOME="${TUNER_JAVA_HOME:-$SDKMAN_JAVA/27.0.1-tem}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "JDK not found at $JAVA_HOME (install the latest stable Temurin with SDKMAN, or set TUNER_JAVA_HOME)" >&2
  exit 1
fi
if [[ ! -d "$ANDROID_HOME/platforms" ]]; then
  echo "Android SDK not found at $ANDROID_HOME (set ANDROID_HOME)" >&2
  exit 1
fi
ANDROID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANDROID_DIR
