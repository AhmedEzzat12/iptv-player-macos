# Appendix F — Build, test, release, and acceptance per phase

Part of the Google TV design (`../2026-11-15-google-tv-design.md`).

## Toolchain

- **JDK**: latest stable GA via SDKMAN (JDK 27 at the time of writing): `sdk install java 27.0.x-tem`, then
  `export JAVA_HOME=/opt/homebrew/opt/sdkman-cli/libexec/candidates/java/<that version>` in every build command and
  script (never rely on a system JDK; `current` points at an old JDK 8 on this Mac). `android/scripts/env.sh`
  exports it and is sourced by the other scripts. Fallback rule in the design (newest JDK the chain supports).
- **Android SDK**: command-line tools into `~/Library/Android/sdk` (`ANDROID_HOME`), packages: `platform-tools`,
  `platforms;android-<targetSdk>`, `build-tools;<latest>`, `emulator`, `system-images;android-<targetSdk>;google-tv;arm64-v8a`
  (Apple silicon host). `adb` is already on PATH from Homebrew; use the SDK's `platform-tools/adb` in scripts so the
  versions match.
- **Gradle**: wrapper committed (`android/gradlew`, version that supports the JDK). Kotlin DSL, version catalog
  `android/gradle/libs.versions.toml` with every version pinned. Use the **latest stable** of each library at
  implementation time (don't copy versions from this doc): AGP, Kotlin, KSP, Compose BOM, `androidx.tv:tv-material`,
  Navigation Compose, Lifecycle/ViewModel, Room, DataStore, WorkManager, Media3 (`exoplayer`, `exoplayer-hls`,
  `datasource-okhttp`, `session`, `ui`), Media3 FFmpeg decoder (built LGPL, see below), OkHttp (+ `mockwebserver` for
  tests), kotlinx-serialization-json, kotlinx-coroutines, Coil 3 (`coil-compose`, `coil-network-okhttp`),
  `androidx.tvprovider`, ZXing `core` (QR), JUnit 5 (core), JUnit 4 + Robolectric + Turbine (Android modules),
  Compose UI test.
- **Kotlin**: `explicitApi()` off, `allWarningsAsErrors` on in `core`, `-Xjvm-default=all`. `jvmToolchain` = the JDK
  above; `jvmTarget`/`compileOptions` = the highest level AGP/D8 accept.
- **Android config**: `minSdk 28`, `compileSdk`/`targetSdk` = Play's current requirement; `applicationId
  app.antenna.player`; `versionCode` = `git rev-list --count HEAD` on `main` (computed in Gradle from git; fall
  back to 1 outside a git checkout); `versionName` from a new `android/VERSION` file (starts `1.0.0`; the Android app
  has its own version line, separate from the Apple `VERSION`).
- Build types: `debug` (applicationIdSuffix `.debug`), `release` (R8 minify + resource shrink, signed with the
  upload key only by the maintainer; locally builds unsigned or with a debug key), and a `scratch` build type
  (applicationIdSuffix `.scratch`, debuggable false, minified) for testing on the owner's TV.
- ABI splits: produce an AAB for Play (all ABIs) and per-ABI APKs for sideloading (armeabi-v7a, arm64-v8a, x86_64).

## Media3 FFmpeg audio decoder

Built from the Media3 repo's `libraries/decoder_ffmpeg` with FFmpeg configured `--disable-gpl --disable-nonfree`
and only the audio decoders needed: `ac3 eac3 dca truehd mlp mp3 aac flac opus vorbis alac`. Script:
`android/ffmpeg/build.sh` (NDK from the SDK), output AAR checked into `android/libs/` **only if** the build is
reproducible from the script and the source versions are recorded in Acknowledgements; otherwise built in CI-free
local step documented in `docs/testing.md`. Same for libmpv (`android/mpv/build.sh`).

## Scripts (`android/scripts/`)

| Script | What it does |
|---|---|
| `env.sh` | exports `JAVA_HOME`, `ANDROID_HOME`, PATH; fails clearly if missing |
| `check-build.sh` | `./gradlew :core:test :data:testDebugUnitTest :player:testDebugUnitTest :app:assembleDebug` + vectors; the Android counterpart of `scripts/test.sh` + `swift build` |
| `emulator.sh` | creates (once) and boots the Google TV AVD `antenna-tv` headless or windowed; prints its serial |
| `install-scratch.sh <serial>` | builds `scratch`, installs it on the device (`adb -s <serial> install -r`), launches it |
| `uninstall-scratch.sh <serial>` | `adb uninstall app.antenna.player.scratch` (and clears its data) |
| `release.sh` | maintainer only: parity check (Appendix E), tests, `bundleRelease`, release notes; never handles signing keys itself (the maintainer's Gradle properties point at the upload key) |

## Testing on the owner's TCL TV

1. On the TV: Settings → System → About → tap "Android TV OS build" 7× → Developer options → **USB/Network
   debugging** (or "Wireless debugging" on newer builds).
2. `adb connect <tv-ip>:5555` (or pair with the code shown for wireless debugging). Accept the prompt on the TV.
3. Record the device in `docs/android-devices.md`: model, Android version, `getprop ro.product.cpu.abilist`,
   RAM (`/proc/meminfo`), and decoders (`adb shell dumpsys media.player` and a small instrumented test that dumps
   `MediaCodecList` and `AudioCapabilities`).
4. Only ever install the `scratch` build (`app.antenna.player.scratch`). Never install over, clear, or uninstall
   `app.antenna.player` or `app.antenna.player.debug` on that TV unless the owner says so. Uninstall the scratch
   build at the end of each session.
5. Test kit on the LAN: `TESTKIT_HOST=0.0.0.0 python3 scripts/testkit/server.py` (the option already exists), then
   use `http://<mac-ip>:8765/...` in the app. Stop it by PID afterwards. Never use real playlists.

## Emulator

- AVD: Google TV image, 1080p, 2 GB RAM (matches the low-end target). The emulator reaches the Mac's
  `127.0.0.1:8765` as `10.0.2.2:8765`.
- The emulator decodes in software: performance and decoder fallback are verified on the TCL, not here.
- UI tests drive the emulator with `adb shell input keyevent` (DPAD_*, ENTER, BACK) and Compose UI tests
  (`performKeyInput`).

## Test kit coverage

The test kit (`scripts/testkit/server.py`, see `docs/testing.md`) serves M3U + XMLTV, an Xtream panel (user/pass
`test`) with live, movies, series, catchup/timeshift, a UA-locked channel, dead channels for failover, and slowed VOD
(`TESTKIT_VOD_RATE`). It has **no Stalker portal**: Stalker is covered by unit tests with `MockWebServer` replaying
recorded portal responses (handshake, get_profile, genres, channels, create_link, VOD pages). Recording real portal
responses is forbidden (credentials); write the fixtures by hand from the Swift client's expectations.

## Acceptance per phase

A phase is done when every item is checked and the commit(s) are in. Each phase ends with `check-build.sh` green and
the Apple checks still green (`scripts/test.sh`, `swift build --product Tuner`).

### Phase 1 — Parity tooling and skeleton
- [ ] `scripts/parity-paths.txt`, `scripts/hooks/commit-msg` (+ its shell test), `scripts/android-backlog.sh`,
      `android/PARITY_BASE`, `android/parity-tags.txt` (empty, with header), `docs/android-parity.md`.
- [ ] `Tests/Vectors/` with the initial corpus generated from Swift; `VectorTests.swift` passing.
- [ ] `CLAUDE.md` section "Android follows the Apple apps"; README → Development mentions the hook.
- [ ] `scripts/release.sh` prints the backlog summary (no behaviour change otherwise).
- [ ] JDK installed via SDKMAN; Android SDK + Google TV AVD; `android/` Gradle project with `core`, `data`,
      `player`, `app` modules; app launches on the emulator to a drawer with empty screens; focus moves with the
      D-pad; Back exits from the drawer.
- [ ] `docs/android-devices.md` with the TCL's details.

### Phase 2 — Core port
- [ ] Every `core` row of Appendix A ported with its Swift tests passing in Kotlin.
- [ ] Kotlin `VectorTest` passes every vector file.
- [ ] `docs/android-parity.md` lists each ported area with its sha.

### Phase 3 — Data
- [ ] Room schema v1 as Appendix B, schema JSON exported and committed; DAO tests (Robolectric) for every read/write
      listed.
- [ ] Sync of the test kit's M3U and Xtream sources end to end (instrumented test on the emulator against
      `10.0.2.2:8765`).
- [ ] Guide ingest with key resolution; `programs(...)` clamping test.
- [ ] Secrets: encrypt/decrypt round trip; undecryptable → `needsPassword`.
- [ ] WorkManager refresh (launch + every 10 min check of stale sources, intervals from settings).
- [ ] Benchmarks on the TCL (release build): 100k-entry M3U < 15 s; 1M-programme gzip XMLTV < 60 s; peak memory
      recorded in `docs/android-devices.md`.

### Phase 4 — Player
- [ ] Both engines play the test kit's HLS, TS, MP4, MKV, catchup; UA-locked channel plays (headers on every
      request).
- [ ] Routing: forced-failure tests with a fake engine for every rule in Appendix C (fallback once, no fallback after
      4xx, 5xx retry, 15 s timeout, EngineMemory only after mpv plays, close-before-open).
- [ ] Watchdog/failover against the test kit's dead channels (auto failover to a duplicate, then reconnect with
      backoff, then the failure card).
- [ ] Progress saving, resume, Up Next countdown, end-of-media stall, quick reopen, Skip Intro (button and
      automatic; the test kit's MKV has chapter markers "Cold Open"/"Opening"…).
- [ ] On the TCL: first frame < 2 s for a live TS channel; AC-3 audio plays (passthrough or decoded); an HEVC
      stream plays; any decoder the TV lacks falls back to mpv; results in `docs/android-devices.md`.
- [ ] The test kit has H.264/AAC media and one MKV; it has no HEVC, AC-3 or "duration longer than the picture"
      file. Add those to the test kit (`scripts/testkit/make_media.sh`, generated with ffmpeg) in this
      phase, documented in `docs/testing.md`, without changing what the Apple test flows rely on.

### Phase 5 — Screens
- [ ] Every screen in Appendix D, with the focus rules, initial focus and Back behaviour listed there.
- [ ] Welcome → QR setup → add the test kit Xtream source from a phone browser → first sync progress → Home rows.
- [ ] Guide grid at 2,000 channels scrolls without dropped frames on the TCL (`adb shell dumpsys gfxinfo`).
- [ ] Settings panes edit the DataStore keys with the listed defaults.

### Phase 6 — Google TV integration and polish
- [ ] Watch Next entries appear on the TCL's Google TV home "Continue watching" row and deep-link back; removed when
      finished.
- [ ] Assistant/remote media keys through MediaSession.
- [ ] Banner, icon, launcher entry; focus audit (every screen reachable and escapable by remote); low-RAM behaviour
      (`onTrimMemory`).
- [ ] Metadata (Cinemeta default, TMDB with a key) on detail pages.
- [ ] Fire TV: one sideload pass on a Fire TV device or emulator if available; features that need Google services
      hide themselves (if no device is available, record that it wasn't tested).

### Phase 7 — Store
- [ ] Play listing text (name Antenna; no provider/content names; "bring your own playlist"), privacy policy adapted
      from `docs/app-store/privacy.md`, Data safety answers (no data collected; network calls to the user's own
      providers and the metadata/skip services listed in Appendix A).
- [ ] Acknowledgements screen + licence texts (LGPL for libmpv/FFmpeg, Apache 2.0, MIT…), source versions listed.
- [ ] Screenshots from the test kit only (TV 1920×1080), committed in `docs/media/android/`.
- [ ] README → "Google TV" section (features, what's missing vs the Apple apps, sideload instructions), `docs/design.md`
      → "Google TV" section, `docs/testing.md` → "Testing the Google TV app", `CLAUDE.md` → Android build/test commands.
- [ ] `android/scripts/release.sh` produces the AAB and per-ABI APKs; the maintainer signs and uploads.
