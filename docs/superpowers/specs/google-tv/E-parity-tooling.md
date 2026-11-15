# Appendix E — Parity tooling: exact specs

Part of the Google TV design (`../2026-11-15-google-tv-design.md`, section "Following Apple changes"). This
appendix specifies the scripts and files precisely enough to write them without guessing. All scripts are bash
(`#!/usr/bin/env bash`, `set -euo pipefail`), run on macOS with the system tools; use `/usr/bin/grep` and
`/bin/ls` explicitly where output matters (zsh/Homebrew shadows, see `CLAUDE.md`).

## Tagged paths

A commit is **tagged-path** when any changed file matches one of:

```
Sources/
iOS/Sources/
AppStore/Mac/Sources/
Tests/TunerCoreTests/
```

`Tests/Vectors/` is **not** a tagged path (it's shared by both apps; changing a vector is itself the signal).
Keep the list in one place: `scripts/parity-paths.txt` (one prefix per line), read by the hook and the backlog
script.

## Trailer grammar

Exactly one line matching this regex in the commit message (anywhere in the trailer block; trailers are the last
paragraph, git-trailer style, so `git interpret-trailers --parse` sees them):

```
^Android: (ported|todo|deferred|n/a)( .+)?$
```

- `ported`: no text required. The same commit must also change at least one file under `android/`.
- `todo <text>`: text required (≥ 10 characters): what to port, in behaviour terms.
- `deferred <feature>`: text required: the feature name from the "not in v1" list (e.g. `deferred downloads`).
- `n/a <why>`: text required (e.g. `n/a AppKit window hosting`).

Android-side trailers:

```
^Ports: [0-9a-f]{7,40}(, ?[0-9a-f]{7,40})*$
^Ports-skipped: [0-9a-f]{7,40} .+$
```

Short shas are resolved with `git rev-parse --verify <sha>^{commit}`; an unresolvable sha fails the hook.

## `scripts/hooks/commit-msg`

Input: `$1` = path of the message file. Behaviour:

1. If `MERGE_HEAD` exists (merge commit) or the message starts with `fixup!`/`squash!`: exit 0.
2. Changed files: `git diff --cached --name-only --diff-filter=ACMRD`.
3. If none is tagged-path: skip to step 6.
4. Count trailer lines matching the `Android:` regex (ignore lines starting with `#`, which git strips). Not exactly
   one → print and exit 1:
   ```
   This commit changes app code (e.g. Sources/Tuner/Views/HomeView.swift) but has no Android trailer.
   Add one line at the end of the message:
     Android: ported            (android/ changes are in this commit)
     Android: todo <what to port>
     Android: deferred <feature Android doesn't have yet>
     Android: n/a <why it's Apple-only>
   See CLAUDE.md → "Android follows the Apple apps".
   ```
5. `ported` with no staged `android/` file → exit 1 with a message saying so. `todo`/`deferred`/`n/a` without text →
   exit 1.
6. If the message has `Ports:`/`Ports-skipped:` lines, verify each sha resolves to a commit (exit 1 otherwise).
7. Exit 0.

The hook must run in < 200 ms (no network, no full-history scans). Test it with a bats-free shell test
`scripts/hooks/test-commit-msg.sh` that creates a temp repo, stages files, and checks exit codes for each case.

Enabling: `git config core.hooksPath scripts/hooks` (documented in README → Development and `CLAUDE.md`).
`scripts/test.sh` prints a one-line warning if `core.hooksPath` isn't `scripts/hooks` (doesn't fail).

## `android/PARITY_BASE`

One line: the full 40-character sha of the Apple commit the initial port was taken from (HEAD of `main` when phase 1
starts). Written once by the builder in phase 1. Commits reachable from it are never in the backlog.

## `android/parity-tags.txt`

For commits that missed their trailer. Format, one per line, `#` comments allowed:

```
<40-char sha> todo|deferred|n/a <text>
```

A line here counts as that commit's trailer. A commit may have a trailer *or* a line, not both (backlog script
warns).

## `scripts/android-backlog.sh`

```
usage: scripts/android-backlog.sh [--all] [--json] [--since <sha>]
```

Algorithm:

1. `base` = `--since` or the content of `android/PARITY_BASE` (error if missing).
2. Commits = `git rev-list --reverse --no-merges <base>..HEAD` (on the current branch; porting sessions run it on
   `main`).
3. For each commit: changed files (`git diff-tree --no-commit-id --name-only -r <sha>`); skip if none is
   tagged-path. Read its trailer (`git log -1 --format=%B <sha>` + regex), else its `parity-tags.txt` line, else
   mark **untagged**.
4. Collect all `Ports:` / `Ports-skipped:` shas from commits in `<base>..HEAD` (any path), resolved to full shas.
5. A `todo` commit is **to port** unless its sha is in that set.
6. Output (text), newest last:
   ```
   Untagged (2):
     3f2a91c  12d  Make seeks feel immediate and reopen a just-closed title from its buffer
   To port (3):
     abc5e2c   4d  todo: play button turns into a spinner while loading — Show loading in the play button…
   Summary: 3 to port, 2 untagged, oldest 12 days.
   ```
   `--all` adds `Deferred (n)` grouped by feature and `Apple-only (n)`. `--json` prints
   `{"untagged":[…],"toPort":[…],"deferred":[…],"na":[…],"summary":{…}}` with objects
   `{sha, shortSha, ageDays, subject, trailer, text}`.
7. Exit code 0 always (it's a report); `--check` flag: exit 1 when untagged or to-port is non-empty (used by the
   Android release script).

## Release integration

- `scripts/release.sh` (Apple): after the tests, run `scripts/android-backlog.sh` if `android/PARITY_BASE` exists and
  print only its summary line prefixed `Android backlog:`. Never fails the release.
- `android/scripts/release.sh`: runs `scripts/android-backlog.sh --check`; on failure prints the report and exits 1
  unless `PARITY_GAP_OK=1`, in which case it writes the to-port list under "Coming from the Apple apps" into the
  release notes file.

## Shared test vectors (`Tests/Vectors/`)

### Layout

```
Tests/Vectors/
  README.md                       what this is, how to add a case, how to regenerate
  stable-id/hash.json
  stable-id/slug.json
  stable-id/sanitize.json
  stable-id/m3u-channel-ids.json
  url-encoding/xtream.json
  normalizer/channel-names.json
  catchup/m3u.json
  m3u/<case>.json                 input file path or inline text → parsed result summary
  xmltv/<case>.json
  category-grouping/menus.json
  category-grouping/display-names.json
  episode-navigation/next-prev.json
  episode-navigation/up-next-countdown.json
  end-of-media/stall.json
  continue-watching/<case>.json
  skip-segments/<case>.json
  stream-resolver/urls.json
  source-fingerprint/fingerprints.json
```

### File format

```json
{
  "function": "StableID.slug",
  "generatedBy": "swift",
  "swiftCommit": "7b464e2",
  "cases": [
    { "name": "arabic with harakat", "input": "أفلامٌ عربية", "expected": "أفلامٌ-عربية" },
    { "name": "only punctuation",   "input": "!!!",          "expected": "category-…" }
  ]
}
```

- `input` / `expected` are JSON values whose shape is fixed per function (documented in `Tests/Vectors/README.md`).
  Dates are ISO-8601 UTC strings; durations seconds as numbers.
- For parsers, `expected` is a summary, not the whole model: counts plus a list of selected fields per item (id,
  name, categoryId, tvgId, providerStreamId, catchupType, …), so the vectors stay readable.
- `input` may be `{"fixture": "sample.m3u"}` pointing into `Tests/TunerCoreTests/Fixtures/`.

### Generating expected values from Swift (the important part)

The expected values are **produced by the Swift implementation**, not written by hand, so the Kotlin port is
checked against what the Apple apps actually do:

1. Phase 1 adds `Tests/TunerCoreTests/VectorTests.swift` with two modes:
   - Normal test run: for every vector file, run each case through the Swift function and `#expect` equality.
   - Regenerate mode (`TUNER_VECTORS_REGENERATE=1 scripts/test.sh --filter VectorTests`): for files whose cases
     have `"expected": null`, compute and write the values back (pretty-printed, stable key order, `swiftCommit`
     updated). Never overwrites a non-null `expected` unless `TUNER_VECTORS_REGENERATE=all`.
   `VectorTests.swift` finds the folder from its own location (`URL(fileURLWithPath: #filePath)` → `../../Vectors`),
   not through the bundle's resources (`Package.swift` only copies `Fixtures`), so regenerate mode can write the
   files back in place. Don't change `Package.swift` for this.
2. To add coverage: write cases with `"expected": null`, run regenerate mode, review the diff, commit.
3. Initial corpus (phase 1), at least: 200 channel names from `Fixtures/sample.m3u`, `scripts/testkit/server.py`'s
   catalog and hand-written tricky ones (Arabic with/without harakat and hamza forms, superscript ᴴᴰ/ᵁᴴᴰ, full-width
   letters, `UK:`/`|AR|`/`[CA]` prefixes, `+1`, `Canal+`, emoji, Turkish İ/ı); 100 slugs/sanitize/hash inputs
   (incl. empty, punctuation-only, 1,000-char, surrogate pairs); 50 username/password pairs for URL encoding
   (`@ : / ? # % + & =`, space, Arabic, emoji); catchup templates covering every placeholder; 30 continue-watching
   scenarios mirroring `SmartContinueWatchingTests.swift`; end-of-media boundaries (exactly 15 s, 30 s duration,
   NaN/Infinity).
4. Kotlin: `android/core/src/test/kotlin/.../VectorTest.kt` reads the same files (path `../../Tests/Vectors`,
   resolved from the Gradle project dir) and runs each case through the Kotlin function; dynamic tests
   (`@TestFactory`) named `<file> / <case name>`.
5. A vector that Kotlin can't match because of a deliberate difference gets `"androidExpected": <value>` next to
   `expected`, plus a line in `docs/android-parity.md`. Use sparingly.

### Rules for later changes

- A Swift fix in a vector area adds a case (with `expected: null` → regenerate) in the same commit. The commit is
  then usually `Android: todo …` (Kotlin fails until ported), or `Android: ported` with the Kotlin fix included.
- Never edit `expected` by hand. If Swift's output changed on purpose, regenerate with `=all` for that file and say
  why in the commit body.

## `docs/android-parity.md`

Created in phase 1:

```markdown
# Android parity

Base: <PARITY_BASE sha>. Backlog: `scripts/android-backlog.sh`.

## Ported areas
| Area | Swift file(s) | Kotlin file(s) | Ported from | Notes |
|---|---|---|---|---|
| StableID | Sources/TunerCore/Parsing/StableID.swift | android/core/.../StableID.kt | 7b464e2 | — |

## Deliberate differences
- Xtream live is requested as `.ts` first (Apple: HLS for AVFoundation). Reason: ExoPlayer plays TS well and starts
  faster; `.m3u8` is the fallback.
- Quick reopen keeps a closed title for 2 minutes by default (Apple: 10). Reason: TV RAM.
```
