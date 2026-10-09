#!/usr/bin/env bash
# Publishes a release from this Mac — no GitHub Actions, nothing to pay for (same flow as Soonbar).
#   1. runs the tests, checks that the iPhone/iPad app still compiles, and builds the Mac app with the version in
#      VERSION (build number = commit count)
#   2. signs the update with your Sparkle key (login keychain; created on first run — Keychain may ask)
#   3. writes appcast.xml and creates GitHub release v<version> with the zip and appcast attached
# Installed copies find the new version through the appcast and update themselves.
#
# Usage: bump VERSION, commit, push, then: scripts/release.sh
# Release notes (shown in the app's update window and on GitHub) are the commit subjects since the previous
# release. To write your own instead: RELEASE_NOTES=notes.txt scripts/release.sh
#
# New or changed UI ships with pictures: if the views changed since the previous release, the release needs new
# screenshots or demo footage in docs/media (committed), and the screenshots to attach to the GitHub release:
#   RELEASE_MEDIA="docs/media/15-ai.png docs/media/16-ai-iphone.png" scripts/release.sh   (a new demo video too)
# For UI changes not worth a picture: NO_RELEASE_MEDIA=1 scripts/release.sh
#
# Back up the signing key once (losing it means installed copies can't verify future updates):
#   "$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)/generate_keys" -x ~/sparkle-private-key.txt
#   → then into a password manager. Soonbar uses the same keychain key, so one backup covers both apps.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"

if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
  echo "Install and sign in to the GitHub CLI first: brew install gh && gh auth login" >&2; exit 1
fi
if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  echo "This branch has no upstream on GitHub yet; publish the branch first." >&2; exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2; exit 1
fi
git fetch --quiet --tags origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]]; then
  echo "Push your commits first — the release tag points at what's on GitHub." >&2; exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists — bump VERSION first." >&2; exit 1
fi

# UI changes need screenshots or demo footage (see the top of this file).
# (macOS bash 3.2 treats an empty array as unset under `set -u`, hence the ${MEDIA[@]+…} forms.)
MEDIA=()
MEDIA_COUNT=0
for file in ${RELEASE_MEDIA:-}; do
  [[ -f "$file" ]] || { echo "RELEASE_MEDIA: $file doesn't exist." >&2; exit 1; }
  MEDIA+=("$file")
  MEDIA_COUNT=$((MEDIA_COUNT + 1))
done
PREVIOUS_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$PREVIOUS_TAG" && "${NO_RELEASE_MEDIA:-}" != "1" ]]; then
  UI_CHANGES="$(git diff --name-only "$PREVIOUS_TAG" HEAD -- Sources/Tuner/Views iOS/Sources | head -5)"
  MEDIA_CHANGES="$(git diff --name-only "$PREVIOUS_TAG" HEAD -- docs/media | head -1)"
  if [[ -n "$UI_CHANGES" && ( -z "$MEDIA_CHANGES" || $MEDIA_COUNT -eq 0 ) ]]; then
    echo "The UI changed since $PREVIOUS_TAG (e.g. ${UI_CHANGES//$'\n'/, })." >&2
    echo "Add screenshots or demo footage to docs/media (test kit only), commit them, and list the new files" >&2
    echo "in RELEASE_MEDIA so they're attached to the release. For changes not worth a picture: NO_RELEASE_MEDIA=1." >&2
    exit 1
  fi
fi

source scripts/sparkle-tools.sh
"$SPARKLE_BIN/generate_keys" >/dev/null
export SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
# Sparkle compares build numbers; the commit count only ever grows on main.
export BUILD_NUMBER="$(git rev-list --count HEAD)"

scripts/test.sh
# The iPhone/iPad app shares the sources: never tag a commit that breaks it. Needs Xcode + XcodeGen;
# SKIP_IOS_CHECK=1 skips it (e.g. on a Mac without Xcode).
if [[ "${SKIP_IOS_CHECK:-}" != "1" ]]; then
  iOS/scripts/check-build.sh
fi
scripts/build-app.sh release
# Stable asset name so releases/latest/download/Tuner.zip always points at the newest build.
ZIP="build/Tuner.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Tuner.app "$ZIP"
NOTES="build/release-notes.txt"
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  cp "$RELEASE_NOTES" "$NOTES"
else
  if [[ -n "$PREVIOUS_TAG" ]]; then RANGE=("$PREVIOUS_TAG..HEAD"); else RANGE=(-n 12); fi # first release: latest changes
  git log "${RANGE[@]}" --no-merges --format=%s \
    | awk '{ print "• " toupper(substr($0, 1, 1)) substr($0, 2) }' > "$NOTES"
  [[ -s "$NOTES" ]] || echo "• Small improvements and fixes." > "$NOTES"
fi
echo "Release notes:"; cat "$NOTES"
scripts/make-appcast.sh "$VERSION" "$BUILD_NUMBER" "$ZIP" "$NOTES"

# Uploads sometimes stall (HTTP 408). gh removes a release whose upload failed, so trying again is safe.
for attempt in 1 2 3; do
  if gh release create "$TAG" "$ZIP" build/appcast.xml ${MEDIA[@]+"${MEDIA[@]}"} \
       --target "$(git rev-parse HEAD)" --title "Tuner $VERSION" --notes-file "$NOTES"; then
    echo "Published $TAG"
    exit 0
  fi
  if gh release view "$TAG" >/dev/null 2>&1; then
    # Created but an asset didn't make it: upload both again.
    gh release upload "$TAG" "$ZIP" build/appcast.xml ${MEDIA[@]+"${MEDIA[@]}"} --clobber && { echo "Published $TAG"; exit 0; }
  fi
  echo "Publishing failed (attempt $attempt of 3); trying again in 15 s…" >&2
  sleep 15
done
echo "Couldn't publish $TAG. build/Tuner.zip and build/appcast.xml are ready; to try again without rebuilding:" >&2
echo "  gh release create $TAG $ZIP build/appcast.xml --target $(git rev-parse HEAD) --title \"Tuner $VERSION\" --notes-file $NOTES" >&2
exit 1
