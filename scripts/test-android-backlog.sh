#!/bin/bash
# Tests for scripts/android-backlog.sh. Run: bash scripts/test-android-backlog.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

expect() {  # expect <description> <condition result 0/1>
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "  ok    $1"; else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; fi
}

cd "$TMP"
git init -q
git config user.email test@example.com
git config user.name Test
mkdir -p scripts android Sources/Tuner docs
cp "$ROOT/scripts/android-backlog.sh" "$ROOT/scripts/android-backlog.py" "$ROOT/scripts/parity-paths.txt" scripts/
printf '# header\n' > android/parity-tags.txt
echo base > docs/a.md
git add -A && git commit -q -m base
git rev-parse HEAD > android/PARITY_BASE
git add -A && git commit -q -m "Record parity base"

commit() {  # commit <file> <message>
  mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; git add -A; git commit -q -m "$2"; git rev-parse HEAD
}

UNTAGGED="$(commit Sources/Tuner/A.swift "Untagged change")"
TODO1="$(commit Sources/Tuner/B.swift "Seek goal

Android: todo port the seek goal behaviour")"
commit android/app/Seek.kt "Port the seek goal

Ports: ${TODO1:0:7}" >/dev/null
TODO2="$(commit Sources/Tuner/C.swift "Spinner in the play button

Android: todo spinner replaces the play button while loading")"
commit Sources/Tuner/D.swift "Downloads tweak

Android: deferred downloads" >/dev/null
commit Sources/Tuner/E.swift "AppKit tweak

Android: n/a AppKit window hosting" >/dev/null
commit android/app/Other.kt "Android only" >/dev/null
commit docs/b.md "Docs only" >/dev/null
LATE="$(commit Sources/Tuner/F.swift "Forgot the trailer")"
SKIPPED="$(commit Sources/Tuner/G.swift "Mac menu

Android: todo add a menu entry for the new action")"
echo "$LATE n/a Mac menu bar only" >> android/parity-tags.txt
commit android/parity-tags.txt "Tag a commit after the fact

Ports-skipped: ${SKIPPED:0:7} the TV has no menu bar" >/dev/null

OUT="$(bash scripts/android-backlog.sh)"
echo "$OUT" | /usr/bin/grep -q "Summary: 1 to port, 1 untagged" ; expect "summary counts" $?
echo "$OUT" | /usr/bin/grep -q "${UNTAGGED:0:7}" ; expect "untagged commit listed" $?
echo "$OUT" | /usr/bin/grep -q "${TODO2:0:7}" ; expect "open todo listed" $?
! echo "$OUT" | /usr/bin/grep -q "${TODO1:0:7}" ; expect "ported todo not listed" $?
! echo "$OUT" | /usr/bin/grep -q "${SKIPPED:0:7}" ; expect "skipped todo not listed" $?
! echo "$OUT" | /usr/bin/grep -q "${LATE:0:7}" ; expect "commit tagged in parity-tags.txt not untagged" $?

ALL="$(bash scripts/android-backlog.sh --all)"
echo "$ALL" | /usr/bin/grep -q "Deferred (1)" ; expect "--all lists deferred" $?
echo "$ALL" | /usr/bin/grep -q "Apple-only (2)" ; expect "--all lists Apple-only (trailer + tags file)" $?

JSON="$(bash scripts/android-backlog.sh --json)"
echo "$JSON" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); assert d["summary"]["toPort"]==1 and d["summary"]["untagged"]==1 and len(d["deferred"])==1' ; expect "--json shape" $?

rc=0; bash scripts/android-backlog.sh --check >/dev/null || rc=$?
[ "$rc" -eq 1 ]; expect "--check fails with open items" $?

rc=0; bash scripts/android-backlog.sh --check --since "$SKIPPED" >/dev/null || rc=$?
[ "$rc" -eq 0 ]; expect "--check passes when nothing is open (--since)" $?

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
