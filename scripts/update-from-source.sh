#!/usr/bin/env bash
# Builds Tuner from source and installs it in place of any installed copy.
# For Macs where downloaded apps are blocked (e.g. managed by an organization), or to run unreleased code.
#
# Usage: scripts/update-from-source.sh          # latest release tag (tested code)
#        scripts/update-from-source.sh --main   # tip of main (unreleased changes)
#
# Needs the Command Line Tools (xcode-select --install). Your library and settings are kept.
# Source builds don't update themselves (they carry no update key); run this again to update.
# Self-cleaning: it builds in a temporary checkout that is deleted when the script ends — on success,
# failure or Ctrl-C — so nothing is left in the repo or on disk except the installed app.
# Optional env:
#   INSTALL_DIR    where to install (default ~/Applications, no admin rights needed)
#   NO_LAUNCH=1    don't open the app afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

USE_MAIN=0
case "${1:-}" in
  --main) USE_MAIN=1 ;;
  "") ;;
  *) echo "Usage: $0 [--main]" >&2; exit 1 ;;
esac

APP="Tuner.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tuner-build.XXXXXX")"
BUILD_TREE="$WORK/src"

cleanup() {
  git worktree remove --force "$BUILD_TREE" 2>/dev/null || rm -rf "$BUILD_TREE"
  rm -rf "$WORK"
  git worktree prune
}
trap cleanup EXIT

echo "==> Updating from GitHub"
git fetch --quiet --tags origin
# Bring the local repo up to date when that can't disturb your work.
if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" && -z "$(git status --porcelain)" ]]; then
  git merge --quiet --ff-only origin/main && echo "    local main is up to date"
else
  echo "    (not on a clean main — leaving your working copy as it is)"
fi

LATEST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
if [[ "$USE_MAIN" == "1" || -z "$LATEST_TAG" ]]; then
  REF="origin/main"
else
  REF="$LATEST_TAG"
fi
echo "==> Building from $REF"

# A throwaway checkout keeps your working copy untouched.
git worktree prune
git worktree add --quiet --detach "$BUILD_TREE" "$REF"

(
  cd "$BUILD_TREE"
  # No update key: source builds never update themselves.
  unset SPARKLE_PUBLIC_KEY
  scripts/build-app.sh release
)
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_TREE/build/$APP/Contents/Info.plist")"

echo "==> Replacing installed copies"
quit_copy() { # Quits a running copy of the app at $1 and waits for it to exit.
  local binary="$1/Contents/MacOS/Tuner"
  pkill -f "^$binary" || return 0
  for _ in $(seq 50); do pgrep -f "^$binary" >/dev/null || return 0; sleep 0.1; done
  echo "    $1 did not quit within 5 s" >&2
}
for dir in /Applications "$HOME/Applications"; do
  if [[ -e "$dir/$APP" && "$dir" != "$INSTALL_DIR" ]]; then
    quit_copy "$dir/$APP"
    if rm -rf "${dir:?}/$APP" 2>/dev/null; then
      echo "    removed $dir/$APP"
    else
      echo "    couldn't remove $dir/$APP (needs admin rights) — delete it in Finder to avoid two copies" >&2
    fi
  fi
done
mkdir -p "$INSTALL_DIR"
quit_copy "$INSTALL_DIR/$APP"
# Copy next to the old app first and swap only once the copy succeeded.
STAGED="$INSTALL_DIR/.$APP.new"
rm -rf "$STAGED"
ditto "$BUILD_TREE/build/$APP" "$STAGED"
rm -rf "${INSTALL_DIR:?}/$APP"
mv "$STAGED" "$INSTALL_DIR/$APP"
echo "    installed $INSTALL_DIR/$APP ($VERSION from $REF)"

if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
  open "$INSTALL_DIR/$APP"
fi
echo "Done."
