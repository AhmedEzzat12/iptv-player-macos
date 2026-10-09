# Working on Tuner (instructions for coding agents)

Tuner is a native IPTV player for macOS (SwiftUI + AppKit, Swift Package) and iPhone/iPad (the same sources built by
an XcodeGen project in `iOS/`) with an Apple TV app–style UI. Read `README.md` for features, `docs/design.md` for architecture and decisions, `docs/testing.md` for the local
test kit. The repository is **public**.

## Ground rules

- **Never create, read, export or move the Sparkle signing key** (it lives in the maintainer's login keychain;
  `generate_keys`, `sign_update` without `--ed-key-file` use it). For tests, make a throwaway key in a scratch folder
  (see `docs/testing.md`) and delete it afterwards.
- **No credentials or provider details in the repo, docs or logs.** Xtream stream URLs contain the account's
  username and password: never store them (downloads resolve them per transfer) and never log URLs (log ids, sizes,
  status codes).
- **Don't touch the maintainer's copy of the app or their data:** bundle id `app.tuner.macos`,
  `~/Library/Application Support/Tuner/`, `~/Movies/Tuner Downloads`, `~/Movies/Tuner Recordings`.
  `build/Tuner.app` is usually the copy they're running (and, after a release, the signed copy that updates itself):
  don't rebuild it while it's running; build test copies elsewhere with `BUILD_DIR=<scratch> scripts/build-app.sh`.
- Kill processes you start by PID. Clean up scratch apps, servers, keys and the scratch app's defaults/caches.

## Build and test

```bash
swift build --product Tuner     # quick compile check
scripts/test.sh                 # TunerCore tests (Swift Testing); keep them all green
scripts/build-app.sh release    # build/Tuner.app (version from VERSION, build number = commit count)
```

- `TunerCore` is UI-free, Swift 6 strict concurrency, and tested. Put logic there with tests; keep the app target
  (`Tuner`, Swift 5 language mode) thin. Use `@ViewState` (alias of `@State`) like the rest of the app.
- Database changes are new GRDB migrations appended in `AppDatabase.migrator` (v1…v5 exist); never edit old ones.
- Match the surrounding code's style and comment density. Logging: `Logger(subsystem: "app.tuner.macos", category: …)`.
- Shell quirks on the maintainer's Mac: use `/usr/bin/log` (zsh has a `log` builtin) and `/usr/bin/grep` / `/bin/ls`
  when output matters; use `ffmpeg -nostdin` inside `while read` loops.

## One codebase for Mac and iPhone/iPad

- `Sources/Tuner` is compiled by both apps. Keep Mac-only code behind `#if os(macOS)` (AppKit, `NSEvent`, `Process`,
  Sparkle, window APIs). When a Mac-only type is needed on iOS, add an iOS version with the same name in `iOS/Sources`
  or map a simple AppKit name in `iOS/Sources/Support/AppKitCompat.swift`.
- iPhone layouts go behind `@Environment(\.tunerCompact)` (never set on the Mac), so the Mac UI doesn't change.
- New features go to both apps unless the platform can't do them; list exceptions in README → iPhone and iPad.
- Check both before committing: `scripts/test.sh`, `swift build --product Tuner`, `iOS/scripts/check-build.sh`.
- Never commit `iOS/Config/Local.xcconfig` (the owner's team ID) or generated `*.xcodeproj`.

## Testing the app end to end

Never against the maintainer's app or library. Use a scratch copy:

1. `BUILD_DIR=<scratch> scripts/build-app.sh release`, then
   `plutil -replace CFBundleIdentifier -string app.tuner.macos.scratch <scratch>/Tuner.app/Contents/Info.plist`
   and `codesign --force --deep -s - <scratch>/Tuner.app`.
2. Launch with `TUNER_DATA_DIR=<scratch>/lib` (an empty or copied library; downloads then stay inside it). Apps opened
   with `open` (and Sparkle relaunches) ignore shell variables: put them in the bundle's `LSEnvironment` instead.
3. Providers: `python3 scripts/testkit/server.py` (M3U + XMLTV, Xtream panel on 127.0.0.1:8765, user/pass `test`).
   `TESTKIT_VOD_RATE=150000` slows movie/episode files so download progress and pausing can be seen.
4. Updates: point a test build at a local feed with `TUNER_UPDATE_FEED` (steps in `docs/testing.md`).
5. Afterwards: `defaults delete app.tuner.macos.scratch`, remove `~/Library/Caches/app.tuner.macos.scratch`.

## Releases and automatic updates (Sparkle 2)

Set up the same way as the maintainer's other app, Soonbar. Details: README → Releasing, `docs/design.md` → Updates.

- Only builds made by `scripts/release.sh` contain `SUPublicEDKey`, so only they update themselves. Plain
  `scripts/build-app.sh` builds never do.
- The **maintainer** releases: bump `VERSION`, commit, push, then `scripts/release.sh`. It refuses a dirty or
  unpushed tree or an existing tag, runs the tests, builds, zips `build/Tuner.zip`, writes the signed
  `build/appcast.xml`, and runs `gh release create v<VERSION>` with both files (retrying stalled uploads).
  Installed copies read `releases/latest/download/appcast.xml`.
- If publishing fails after the build, the built files can be published as they are:
  `gh release create v<VERSION> build/Tuner.zip build/appcast.xml --target <full commit SHA> --title "Tuner <VERSION>" --notes-file build/release-notes.txt`
  (only when the maintainer asks; pass the full 40-character SHA).
- The build number (`CFBundleVersion`) must keep increasing; it's the commit count on `main`.
- **New or changed UI ships with pictures.** Before a release whose changes touch the UI, capture screenshots of
  the new UI (Mac, and iPhone when it differs) and/or add it to the demo video, commit them in `docs/media/` (and
  the README gallery), and pass the screenshots in `RELEASE_MEDIA` so they're attached to the GitHub release.
  `release.sh` refuses a release whose views changed without new media unless `NO_RELEASE_MEDIA=1` (for changes
  not worth a picture). Retire pictures of features that were removed.

## Docs and media

- When behaviour changes, update `README.md`, `docs/design.md` and `docs/testing.md` in the same change.
- Screenshots and the demo video (`docs/media/`) come from the test kit only: no real provider content.
  If you re-record, capture a scratch copy; macOS draws a grey "being recorded" pill over the traffic lights, which
  has to be covered in post.

## Commits

Small, reviewable commits. Message: a plain sentence as the subject (no `feat:` prefixes), then a short body with
bullets explaining what changed and why, as in `git log`.
