# Google TV Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Parity tooling that makes every Apple commit say what it means for Android, plus an Android TV skeleton
that builds, tests and launches on the Google TV emulator.

**Architecture:** Bash + Python 3 scripts in `scripts/` read git history (no state files besides `android/PARITY_BASE`
and `android/parity-tags.txt`). Shared JSON test vectors in `Tests/Vectors/` are filled by a Swift test in
regenerate mode. A Gradle multi-module project in `android/` (`core` JVM, `data`, `player`, `app` Android).

**Tech Stack:** bash 3.2-compatible scripts, Python 3 (stdlib only), Swift Testing, Kotlin, Gradle (Kotlin DSL,
version catalog), Compose for TV, JUnit 5.

**Spec:** `docs/superpowers/specs/2026-11-15-google-tv-design.md` + `docs/superpowers/specs/google-tv/E-parity-tooling.md`
and `F-build-test-release.md`.

## Global Constraints

- Apple code under `Sources/` and `iOS/` is not changed. Apple checks stay green: `scripts/test.sh`,
  `swift build --product Tuner`.
- Scripts run with macOS's `/bin/bash` 3.2 (no associative arrays, no `mapfile`); Python with `python3 -I`, stdlib only.
- Tagged paths: `Sources/`, `iOS/Sources/`, `AppStore/Mac/Sources/`, `Tests/TunerCoreTests/` (from `scripts/parity-paths.txt`).
- Trailer regex `^Android: (ported|todo|deferred|n/a)( .+)?$`; `todo` text ≥ 10 chars; `deferred`/`n/a` text required.
- JDK: latest stable GA via SDKMAN, `JAVA_HOME` set explicitly in every script.
- applicationId `app.antenna.player`, visible name "Antenna", minSdk 28.
- Never log URLs; no credentials in the repo.

## Review Focus

- A commit whose message has `# comment` lines mentioning `Android:` must not count them (git strips comments).
- `Ports-skipped: <sha> <reason with spaces>` must resolve only the sha.
- Commits that touch only `android/` or docs must never be reported as untagged.
- A `todo` named by `Ports:` in a later commit must leave the backlog.
- The hook must work when run from a subdirectory (`git commit` from `android/`): paths resolve from the repo root.

---

### Task 1: commit-msg hook and its test

**Files:** Modify (rewrite): `scripts/hooks/commit-msg`, `scripts/hooks/test-commit-msg.sh`; keep `scripts/parity-paths.txt`.

- [ ] Write `test-commit-msg.sh`: temp repo, copies the hook and `parity-paths.txt`, runs the hook directly on
      message files with staged changes. Cases (exit code): no tagged file → 0; tagged + no trailer → 1; tagged +
      `Android: n/a AppKit` → 0; tagged + `Android: todo short` → 1; tagged + `Android: todo port the seek goal` → 0;
      tagged + `Android: ported` without android/ → 1, with android/ file → 0; two trailers → 1; trailer only inside a
      `#` comment → 1; `fixup! x` → 0; `Ports-skipped: <real sha> not on TV` → 0; `Ports: deadbeef` → 1; run from a
      subdirectory → same results.
- [ ] Run it: fails against the old hook.
- [ ] Rewrite the hook (`cd "$(git rev-parse --show-toplevel)"`, merge detection via `git rev-parse -q --verify MERGE_HEAD`,
      strip `#` lines, resolve shas with `^{commit}`).
- [ ] Run it: all pass.

### Task 2: backlog report

**Files:** Create `scripts/android-backlog.py`; rewrite `scripts/android-backlog.sh` as a wrapper (`exec python3 -I …`);
create `scripts/test-android-backlog.sh`. Set `android/PARITY_BASE` to the branch point (current `main` HEAD).

- [ ] Test script: temp repo with base commit, then commits: untagged Sources change; `todo` commit; a commit
      `Ports: <todo sha>`; another `todo`; `deferred`; `n/a`; android-only commit; a commit tagged via
      `parity-tags.txt`. Expect: text summary `1 to port, 1 untagged`; `--json` keys; `--check` exit 1; `--all` lists
      deferred and Apple-only.
- [ ] Implement per Appendix E (text, `--json`, `--all`, `--since`, `--check`).
- [ ] Tests pass; run on the real repo.

### Task 3: shared vectors

**Files:** Create `Tests/Vectors/README.md`, `Tests/Vectors/stable-id/{hash,sanitize,slug}.json`,
`Tests/Vectors/normalizer/channel-names.json`, `Tests/Vectors/end-of-media/stall.json`,
`Tests/TunerCoreTests/VectorTests.swift`.

- [ ] Vector files with `expected: null` cases (Arabic with harakat/hamza, superscript ᴴᴰ, full-width, prefixes,
      emoji, empty, punctuation-only, long strings).
- [ ] `VectorTests.swift`: compare mode + regenerate mode (`TUNER_VECTORS_REGENERATE=1|all`), folder found via `#filePath`.
- [ ] `TUNER_VECTORS_REGENERATE=1 scripts/test.sh --filter VectorTests` fills values; then `scripts/test.sh` all green.

### Task 4: docs and release hook-up

**Files:** `docs/android-parity.md` (new), `CLAUDE.md` (new section), `README.md` (Development: enable hook),
`scripts/release.sh` (print backlog summary), `scripts/test.sh` (warn if hook not enabled),
`docs/superpowers/specs/google-tv/E-parity-tooling.md` (wrapper + Python note).

### Task 5: Android toolchain and skeleton

**Files:** `android/` Gradle project: `settings.gradle.kts`, `build.gradle.kts`, `gradle/libs.versions.toml`, wrapper,
`core/` (JVM, JUnit 5, one smoke test), `data/`, `player/` (Android libraries, empty), `app/` (Compose for TV:
`MainActivity`, drawer with Search/Home/Live TV/Movies/TV Shows/Favorites/Settings, placeholder screens, banner),
`scripts/env.sh`, `scripts/check-build.sh`, `scripts/emulator.sh`, `VERSION`.

- [ ] Install latest stable JDK (SDKMAN) and Android command-line SDK; record versions.
- [ ] `check-build.sh` green; app launches on the Google TV emulator; D-pad moves focus; Back on the drawer exits.

### Task 6: verify

- [ ] `scripts/test.sh`, `swift build --product Tuner`, `android/scripts/check-build.sh`, hook and backlog tests.
