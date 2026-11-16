#!/bin/bash
# Tests for scripts/hooks/commit-msg. Run: bash scripts/hooks/test-commit-msg.sh
# Builds a throwaway repo, stages files and runs the hook on message files; prints one line per case.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

cd "$TMP"
git init -q
git config user.email test@example.com
git config user.name Test
mkdir -p scripts/hooks Sources/Tuner android docs
cp "$ROOT/scripts/hooks/commit-msg" scripts/hooks/commit-msg
cp "$ROOT/scripts/parity-paths.txt" scripts/parity-paths.txt
echo base > docs/base.md
git add -A
git commit -q --no-verify -m "base"
BASE_SHA="$(git rev-parse HEAD)"

# check <description> <expected exit> <message> [dir to run from]
check() {
  local desc="$1" expected="$2" message="$3" dir="${4:-.}"
  printf '%s\n' "$message" > "$TMP/.msg"
  local rc=0
  (cd "$dir" && bash "$TMP/scripts/hooks/commit-msg" "$TMP/.msg") >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expected" ]; then
    PASS=$((PASS + 1)); echo "  ok    $desc"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $desc (expected $expected, got $rc)"
  fi
}

stage_only() {  # unstage everything, then stage the given files (created if missing)
  git reset -q
  local f
  for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$RANDOM" >> "$f"; git add "$f"; done
}

stage_only docs/readme.md
check "docs only, no trailer" 0 "Update docs"

stage_only Sources/Tuner/A.swift
check "tagged, no trailer" 1 "Change a view"
check "tagged, n/a with reason" 0 "Change a view

Android: n/a AppKit window hosting"
check "tagged, n/a without reason" 1 "Change a view

Android: n/a"
check "tagged, todo too short" 1 "Change a view

Android: todo short"
check "tagged, todo with text" 0 "Change a view

Android: todo port the seek goal behaviour"
check "tagged, deferred with feature" 0 "Change a view

Android: deferred downloads"
check "tagged, ported without android/" 1 "Change a view

Android: ported"
check "tagged, two trailers" 1 "Change a view

Android: n/a AppKit
Android: todo port the seek goal behaviour"
check "trailer only in a # comment" 1 "Change a view
# Android: n/a AppKit"
check "unknown trailer kind" 1 "Change a view

Android: maybe later on"
check "fixup commit" 0 "fixup! Change a view"
check "squash commit" 0 "squash! Change a view"
check "run from a subdirectory, no trailer" 1 "Change a view" android
check "run from a subdirectory, with trailer" 0 "Change a view

Android: n/a AppKit window hosting" android

stage_only Sources/Tuner/A.swift android/app/Main.kt
check "tagged, ported with android/" 0 "Port it

Android: ported"

stage_only Tests/TunerCoreTests/X.swift
check "tests are tagged too" 1 "Add a test"

stage_only android/app/Main.kt
check "android only, Ports: real sha" 0 "Port the seek goal

Ports: ${BASE_SHA:0:7}"
check "android only, Ports: two shas" 0 "Port two

Ports: ${BASE_SHA:0:7}, $BASE_SHA"
check "android only, Ports: unknown sha" 1 "Port it

Ports: deadbeef"
check "Ports-skipped with a reason" 0 "Skip it

Ports-skipped: ${BASE_SHA:0:7} not relevant on a TV remote"
check "Ports-skipped unknown sha" 1 "Skip it

Ports-skipped: deadbeef not relevant"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
