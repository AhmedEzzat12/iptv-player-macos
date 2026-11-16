#!/bin/bash
# What the Android app (Google TV) still has to follow from the Apple apps: commits since android/PARITY_BASE that are
# untagged or tagged "Android: todo" and not yet ported. See docs/superpowers/specs/google-tv/E-parity-tooling.md.
# usage: scripts/android-backlog.sh [--all] [--json] [--since <sha>] [--check]
set -euo pipefail
exec python3 -I "$(dirname "$0")/android-backlog.py" "$@"
