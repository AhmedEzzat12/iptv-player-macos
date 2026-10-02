# Sourced by make-appcast.sh and release.sh. Exports SPARKLE_BIN: Sparkle's command-line tools (sign_update,
# generate_keys) from the Sparkle package SwiftPM already downloaded, so they always match Package.resolved.
swift package resolve >/dev/null
SPARKLE_BIN="$(find .build/artifacts -path '*Sparkle/bin' -type d 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "Sparkle's tools weren't found under .build/artifacts (swift package resolve should fetch them)." >&2
  exit 1
fi
export SPARKLE_BIN
