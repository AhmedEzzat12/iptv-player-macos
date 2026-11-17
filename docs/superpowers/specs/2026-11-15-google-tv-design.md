# Antenna for Google TV — design

Date: 2026-11-15. Status: draft for the owner's approval. Reviewed once by a builder check; its open questions
are answered below.

**For the implementer.** This document is the overview and the decisions. The detailed specs are in
`google-tv/`, and they win over this overview where they're more specific:

| Appendix | Contents |
|---|---|
| [A — Port map](google-tv/A-port-map.md) | Every Swift file to port, its Kotlin destination, responsibilities, Swift→Kotlin traps, tests to port |
| [B — Data](google-tv/B-data.md) | Room schema column by column, ids, secrets, backup, ingest rules, queries |
| [C — Player](google-tv/C-player.md) | Engine interface, ExoPlayer/mpv specifics, routing, watchdog, progress, Up Next, remote keys, chrome |
| [D — TV UI](google-tv/D-ui.md) | Every screen with layout, focus and Back rules, QR setup, settings keys/defaults, Watch Next, states |
| [E — Parity tooling](google-tv/E-parity-tooling.md) | Hook, backlog script, trailers, shared test vectors generated from Swift |
| [F — Build, test, release](google-tv/F-build-test-release.md) | Toolchain, Gradle, scripts, TCL and emulator testing, acceptance checklist per phase |

The Swift code is the source of truth for exact algorithms; the appendices say which file to read and what to keep.
Where an appendix and the Swift code disagree on behaviour, the Swift code wins unless the difference is listed as
deliberate (`docs/android-parity.md`).

## Intent

Bring Tuner to the living-room TV: a Google TV / Android TV app with the same core experience as the Mac and
iPhone/iPad apps (sources, live guide, movies and shows, a great player), driven entirely by a TV remote. It ships
on the Play Store under the store name **Antenna**, like the other store apps.

Android TV boxes are where most IPTV is watched on Android, which is why the first Android target is the TV, not
phones.

## Goals

- A native Google TV app that feels at home on the TV and recognisably like Antenna on Apple devices: hero and
  shelves on Home, a guide grid with live preview, poster grids, detail pages, a player with chrome that auto-hides.
- Everything works with a D-pad remote (OK, Back, arrows, channel up/down, play/pause, mic). Nothing needs touch.
- Same behaviour as `TunerCore` for everything the first version covers: same parsing, same guide matching, same
  stream URLs, same resume and Up Next rules. Where the Swift code has tests, the Kotlin port passes the same cases.
- Ready for the Play Store from the first build: contentless, only LGPL/permissive dependencies.
- Also installs and runs on Fire TV as a sideloaded APK (no Google Play services). Not listed on the Amazon
  Appstore. Watch Next and in-app voice search detect when they're unavailable and hide themselves; one test pass.

## Non-goals (first version)

- **Phones and tablets.** The manifest requires `android.software.leanback`, so the Play Store offers it only on TVs.
- **Sync with the Mac/iPhone/iPad apps.** Google TV can't reach iCloud Drive. Deferred to a later version, which
  needs a store all three apps can use (Google Drive, WebDAV…). The first version keeps ids sync-ready (below).
- Downloads (TV boxes have little storage), recording, AirPlay, picture-in-picture, Sparkle (Play updates the app).
- On-device "AI" features: recommendations, natural-language search, smart guide matching, Top 10. The exact-match
  guide resolution (override → Stalker → tvg-id → normalised name) is in; the fuzzy matcher (`GuideMatcher`) isn't.
- Audio enhancements, sleep timer, reminders, IMDb episode ratings, trailers, global Google TV search integration.
- **Payments.** The Play app is free with no in-app purchase in v1 **(owner)**. No billing code, no licence checks.
  TMDB stays "bring your own key", as on Apple.

These come in later versions, ported from `TunerCore` the same way.

## Anti-goals (a failure even if it works)

- Shipping or linking to any content: no built-in playlists, channels, logos or list links (Play policy and
  `docs/app-store/README.md` rules apply here too).
- GPL code in the app (the Play build is distributed, like the App Store ones).
- Logging stream URLs or storing Xtream stream URLs (they contain the username and password). Log ids, sizes,
  status codes.
- Sending playlist credentials to any outside service, including during setup.
- Any screen that can't be reached or left with the remote alone, or a focus trap.

## Constraints

- The repo is public and Tuner's code is PolyForm Noncommercial (`LICENSE.md`); the Android code is too.
- The Apple apps must not change because of this work: the Android app lives in its own folder and builds with its
  own tools. No edits to `Sources/` or `iOS/` as part of this project. The parity tooling adds a few files outside
  `android/` (listed in "Following Apple changes").
- The Apple apps remain the reference. Later Apple features and fixes reach Android through the tag-and-batch
  mechanism in "Following Apple changes" **(owner)**.
- Build machine: the maintainer's Mac. JDKs come from SDKMAN (`/opt/homebrew/opt/sdkman-cli/libexec/candidates/java/`;
  8.0.462-zulu, 8.0.472-amzn, 11.0.29-tem, 17.0.16-tem and 25.0.1-tem are installed, and `current` points at JDK 8: always
  use a named version path, never `current`; the newest stable JDK isn't installed yet); Gradle and adb are installed via
  Homebrew. The build uses the latest stable JDK (see Decisions → JDK). The Android SDK isn't
  installed in the default location yet; the builder installs the command-line SDK and a Google TV emulator image.
- **Test hardware: the owner's TCL TV with Google TV** **(owner)**, reached with `adb connect <tv-ip>` (Developer
  options → network/wireless debugging). It's the reference device for decoders, audio passthrough and the
  performance targets. First step of phase 1: record its ABI list (`adb shell getprop ro.product.cpu.abilist`),
  Android version, RAM and codecs (`adb shell dumpsys media.player` / `MediaCodecList`) in `docs/android-devices.md`.
  TCL Google TVs often run a 32-bit userland, so armeabi-v7a may be the ABI that matters most.
- TV hardware is weak: the target class is a TCL / Chromecast with Google TV / budget box (2 GB RAM, slow storage).
  Playlists reach 100k+ entries and guides millions of programmes, so parsing streams and inserts are batched.

## Approaches considered

| Approach | Trade-offs | Verdict |
|---|---|---|
| **A. Native Kotlin**: Compose for TV UI, Media3/ExoPlayer + libmpv fallback, `TunerCore` ported to Kotlin with the same test cases | Mature tools, the best TV fit, no toolchain risk. Cost: the logic exists twice; fixes must land in both | **Chosen by the owner** |
| B. Compile Swift `TunerCore` for Android, Kotlin UI over JNI (swift-java) | One copy of the logic, existing tests. But URLSession is missing/partial on Android (HTTP, downloads depend on it), GRDB has no official Android support (7.11.1 failed to build with Swift 6.3 for Android in July 2026), JNI + Swift concurrency glue, ~30–50 MB of Swift runtime | Rejected: effort goes to the toolchain, not the app |
| C. Skip (SwiftUI → Compose) | The UI needs a TV redesign anyway, so translating the SwiftUI buys little; TV support unclear | Dropped |
| D. Flutter / React Native | Rewrites everything, including UI and core, with weaker players | Dropped |

## Decisions

Calls the owner made are marked **(owner)**. Everything else is the designer's call, which the builder may revisit
with a reason.

| Concern | Decision | Why |
|---|---|---|
| Platform | Google TV / Android TV **(owner)**, minSdk 28 (Android 9), targetSdk = Play's current requirement | Covers nearly every TV box in use |
| Language and UI | Kotlin, Jetpack Compose with `androidx.tv:tv-material` **(owner: native Kotlin)** | Google's TV toolkit; focus handling built in |
| JDK | **Latest stable (GA) JDK** **(owner)**: JDK 27 at the time of writing (Temurin via SDKMAN, `sdk install java 27.x-tem`). Gradle runs on it (Gradle 9.8+ supports Java 27) and it is the toolchain (`jvmToolchain(27)`, with `JAVA_HOME` pointing at the SDKMAN candidate, never a system JDK). Bytecode targets the highest Java level the Android Gradle plugin and D8 accept (`jvmTarget`/`compileOptions`), since app and `core` code both have to be dexed. Move to each new GA JDK once Gradle, AGP and Kotlin support it | Owner's requirement. If a tool in the chain (AGP, Kotlin, Robolectric, a Gradle plugin) fails on the newest JDK, fall back to the newest JDK it supports (25 LTS today) and record why in `docs/design.md` |
| Where | `android/` in this repo (Gradle, Kotlin DSL, version catalog) | Reuses the test fixtures, the test kit and the docs |
| App identity | applicationId `app.antenna.player` (same as the App Store apps); name shown to users "Antenna"; code, modules and log tags stay "Tuner" | Matches the store apps and `CLAUDE.md` naming rules |
| Distribution | Play Store, contentless, LGPL/permissive only; also sideloadable APK | Same rules as the App Store builds |
| Sync | None in v1 **(owner)**; ids sync-ready | Google TV has no iCloud Drive |
| HTTP | OkHttp (one client; per-source User-Agent/Referer headers as in `HTTPClient`) | Standard, supports what the providers need |
| JSON | kotlinx.serialization, lenient like `LenientJSON` (numbers as strings, nulls, empty arrays as objects) | Xtream panels return sloppy JSON |
| Database | SQLite through Room, WAL; bulk replace per source in one transaction with prepared statements, as `AppDatabase+Library` does | Jetpack standard. If ingest benchmarks miss the targets below, drop to raw `SupportSQLiteDatabase` statements for the hot paths |
| Credentials | Passwords stored encrypted with a key held in the Android Keystore; the rest of the source row in the database | The app sandbox already protects the file; this keeps passwords out of backups and dumps |
| Backup and new TV | Android Auto Backup restores the database and settings but not passwords (the Keystore key doesn't travel). Restored sources show "Password needed" and reopen the QR setup page pre-filled with everything else | Playlists, favourites and progress survive a new TV; passwords never leave the device |
| Version code | Commit count on `main`, as `CFBundleVersion` on Apple | Always increases; one rule across apps |
| Images | Coil 3 with a bounded memory cache (low-RAM aware) and a disk cache | Posters and logos dominate memory on TV |
| Playback | Media3 ExoPlayer first, libmpv fallback (see Player) | Same split as the Apple apps |
| Media session | Media3 `MediaSession` | Remote media keys and Google Assistant ("pause") work through it |
| Background work | Playlist and guide refresh with WorkManager (on launch and every N hours, as on Apple) plus a manual "Refresh" | TV apps get killed in the background |
| Logging | `android.util.Log` behind a small `TunerLog` wrapper; never URLs | Credential rule |

## Architecture

```
android/
  settings.gradle.kts, build.gradle.kts, gradle/libs.versions.toml, gradlew
  core/      Kotlin/JVM module, no Android: models, parsers, provider clients, catchup URLs, title parsing,
             category grouping, episode navigation, Continue Watching / Up Next rules, skip-segment logic,
             stream resolution. Unit-tested on the JVM (fast, runs on the Mac without an emulator).
  data/      Android library: Room database (schema mirrors the Apple tables the v1 features need), repositories,
             sync/guide services (coroutines), WorkManager jobs, Keystore-backed secret storage.
  player/    Android library: PlaybackEngine interface, ExoPlayerEngine, MpvEngine, PlayerSlot (routing, timeout,
             failover, end-of-media stall, engine memory), MediaSession.
  app/       The TV app: Compose for TV screens, navigation, focus, QR setup server, Watch Next publishing.
  scripts/   check-build.sh (assemble + unit tests), emulator helpers.
```

`core` mirrors `Sources/TunerCore` folder by folder (`Parsing`, `Providers`, `Models`, `Services`, `Skip`…) and keeps
the Swift type names, so a reader can find the counterpart of any file. Keeping `core` free of Android means its
tests run with plain JUnit and the parity fixtures.

Data flow follows the Apple app: services write in single transactions off the main thread; screens observe Room
`Flow`s (the counterpart of `libraryRevision` / `guideRevision` / `userRevision`) and a `ViewModel` per screen
exposes immutable state.

### Ids

Local ids use the same scheme as `StableID` (`"<sourceId>_<suffix>"`, random source id per device), and the
`SourceFingerprint` logic is ported with its tests. Nothing uses them across devices yet; this keeps a later sync
version compatible with the Apple apps' sync files without a migration.

## What gets ported from TunerCore (v1)

Port with tests (each Swift test case in these areas gets a Kotlin counterpart; file fixtures are read from
`../Tests/TunerCoreTests/Fixtures` directly, not copied):

- `Parsing/`: `M3UParser`, `XMLTVParser` (a streaming parser: no DOM, constant memory), `Gzip` (multi-member,
  `java.util.zip` handles it with a loop), `ChannelNameNormalizer`, `StableID`, `CatchupURLBuilder`, `TitleParser`.
- `Providers/`: `XtreamClient`, `StalkerClient` (handshake, token refresh, MAC handling).
- `Networking/`: `LenientJSON` behaviour; `HTTPClient` headers and retry rules.
- `Models/`: `CategoryGrouping` (English and Arabic category names into menus), `EpisodeNavigation`,
  `SmartContinueWatching`, `Library`, `VOD`, `Channel`, `Program`, `Source`.
- `Services/`: `SyncService` (playlist ingest), `GuideService` (ingest + key resolution, without the fuzzy matcher),
  `StreamResolver`.
- `Skip/`: `SkipSegments`, `SkipTracker`, `SkipSegmentService` (online lookups + cache). `SkipLearner` can wait.
- `Metadata/`: `CinemetaClient`, `TMDBClient`, `TitleMatcher`, `MetadataService` (logos, backdrops, cast, ratings,
  episode pictures).
- `CloudSync/SourceFingerprint` only (for sync-ready ids).

Also port the end-of-media rule (`EndOfMediaStall`: stopped advancing for 3 s within the last 15 s, not paused,
means finished). It lives in `TunerCore` (`Models/EpisodeNavigation.swift`) with tests in
`EpisodeNavigationTests.swift`, so it goes to `core` with those tests. `PlayerSlot` and `EngineMemory` (30 days, per
channel/movie/episode, episode marks its show) live in the Apple app target (`Sources/Tuner/Player/`) and have no
Swift tests: port them from that code and write new tests for them in `player`.

### Keeping the two in step

Each ported Kotlin file starts with a one-line comment naming its Swift counterpart. `docs/android-parity.md` lists
every ported area, the Swift commit it was ported from, and deliberate differences (the Xtream live `.ts` request
below is the first). How later Apple features and fixes reach Android is the next section.

## Following Apple changes: tag each commit, port in batches

Chosen by the owner over porting in the same change (doubles the cost of every Apple fix) and a periodic review
(decides without the change's context; misses leave no trace). Most Apple changes land in `Sources/Tuner` (views,
app, player), not `TunerCore`, so tests alone can't carry parity: every change is classified when it's made, by
the session that made it, and ported later in batches. Apple work is never blocked by Android lag.

### 1. Every Apple commit says what it means for Android

A commit that touches `Sources/`, `iOS/Sources/`, `AppStore/Mac/Sources/` or `Tests/TunerCoreTests/` ends with one
trailer line (after the body, before `Co-Authored-By`):

| Trailer | Meaning | Blocks an Android release? |
|---|---|---|
| `Android: ported` | The same commit also changes `android/` | — |
| `Android: todo <one line: what to port>` | Applies to a feature the Android app has; port it | Yes, until ported or skipped |
| `Android: deferred <feature>` | Changes a feature Android doesn't have yet (downloads, recommendations…). When that feature is ported it starts from the Swift code at that time, so this is a record, not work | No |
| `Android: n/a <why>` | Apple-only (AppKit hosting, Sparkle, iCloud, App Store review, iOS layout…) | No |

The commit body (bullets of what changed and why, as today) is what the porting session reads, so `todo` commits
describe the behaviour, not just the code.

### 2. A hook makes sure nothing goes untagged

- `scripts/hooks/commit-msg` (versioned; enabled once per clone with `git config core.hooksPath scripts/hooks`,
  documented in README and `CLAUDE.md`) refuses a commit that touches those paths without exactly one `Android:`
  trailer, and refuses `Android: ported` when no `android/` file is staged. Merge commits and commits touching only
  docs, media, `VERSION`, `android/` or other scripts pass.
- A commit that slipped through (made with `--no-verify`, or before the hook was enabled) is tagged after the fact
  in `android/parity-tags.txt` (`<full sha> todo|deferred|n/a <text>`), since pushed commits can't be reworded.
- `android/PARITY_BASE` holds the Apple commit the Android port started from. Commits before it are covered by the
  initial port, which reads the code at that commit.

### 3. The backlog comes from git history

`scripts/android-backlog.sh` lists, for commits after `PARITY_BASE`:

- **Untagged:** commits touching the tagged paths with no trailer and no `parity-tags.txt` line.
- **To port:** `todo` commits that no later commit names in a `Ports: <sha>[, <sha>…]` trailer (the porting
  commit) or a `Ports-skipped: <sha> <why>` trailer (on inspection, it doesn't apply to the TV).
- With `--all`, also `deferred` and `n/a`, grouped by feature, for audits.

Each line shows the short sha, age in days, the trailer text and the commit subject; `--json` gives the same for
scripts and sessions. There's no hand-kept backlog file that could drift from the history.

### 4. Shared test cases for the logic

- `Tests/Vectors/<area>/<case>.json` holds language-neutral cases: an input (inline, or a path into
  `Tests/TunerCoreTests/Fixtures`) and the expected output. A small Swift harness (`VectorTests.swift` in
  `TunerCoreTests`) and its Kotlin twin in `android/core` run every case.
- Areas: M3U and XMLTV parsing, `ChannelNameNormalizer`, `CatchupURLBuilder`, `TitleParser`, `CategoryGrouping`,
  `StableID`, `SourceFingerprint`, `EpisodeNavigation`, `SmartContinueWatching`, `SkipSegments`, stream URL building
  in `StreamResolver`, the end-of-media rule. A fix in one of these adds a case here (in addition to, or instead of,
  a Swift-only test). The Kotlin suite then fails until the fix is ported, which is the point.
- Existing Swift tests aren't converted wholesale; phase 2 ports them by hand, and new cases go into the vectors.

### 5. Porting sessions

Started by the owner ("port the Android backlog") or offered by a session when the backlog is long; local, not a
cloud routine, because player and UI changes must be checked on the owner's TCL TV.

1. Run `scripts/android-backlog.sh`; fix any untagged commits first (tag them in `parity-tags.txt`).
2. In a worktree on a branch `android/port-<date>`: for each item, read `git show <sha>` and its body, build the TV
   version (a translation for logic; a TV-appropriate design for UI: same behaviour, remote-first), and commit with
   `Ports: <sha>`. Related items may share a commit.
3. Run the Kotlin tests, the vectors, and the end-to-end check on the emulator; player and UI items also on the TCL.
4. Update README → Google TV (what the TV app lacks) and `docs/android-parity.md` (deliberate differences), then
   open a PR for the owner.

### 6. Release gates

- **Android release** (`android/scripts/release.sh`) refuses while the backlog has untagged or to-port items, unless
  `PARITY_GAP_OK=1`, in which case the open items are listed in the release notes ("Coming from the Apple apps").
- **Apple release** (`scripts/release.sh`) never blocks on Android. It prints `Android backlog: N to port, M
  untagged, oldest D days`, so lag stays visible.

### 7. Rules added to `CLAUDE.md`

In the same change that adds `android/`, a section along these lines:

> **Android follows the Apple apps.** Commits touching `Sources/`, `iOS/Sources/`, `AppStore/Mac/Sources/` or
> `Tests/TunerCoreTests/` end with one `Android:` trailer: `ported` (android/ changed too), `todo <what>`,
> `deferred <feature>` or `n/a <why>`. Describe behaviour in the body so it can be ported without you. A logic
> fix in a vector area adds a case to `Tests/Vectors`. Android commits that port a change say `Ports: <sha>`.
> `scripts/android-backlog.sh` shows what's outstanding. Enable the hook once: `git config core.hooksPath
> scripts/hooks`.

### Changes outside `android/` this needs

The Apple apps' code doesn't change, but these do. Phase 1: `scripts/parity-paths.txt`, `scripts/hooks/commit-msg`
and `test-commit-msg.sh`, `scripts/android-backlog.sh` (+ `.py`, `test-android-backlog.sh`), a printed line in
`scripts/release.sh`, a hook warning in `scripts/test.sh`, `Tests/Vectors/` (+ README) and `VectorTests.swift`
(test-only), `docs/android-parity.md`, `docs/android-devices.md`, `CLAUDE.md` and README. Phase 4: new test-kit
media (`scripts/testkit/make_media.sh`, `server.py` catalog) without changing what Apple test flows rely on.
Tagging starts on the day the port starts.

## Player

- **Engines.** `PlaybackEngine` interface as on Apple (open, play/pause, seek, tracks, position, state, errors).
  `ExoPlayerEngine` plays HLS (TS and fMP4 segments), progressive MPEG-TS, MP4 and MKV. `MpvEngine` uses libmpv
  rendering into a `SurfaceView` (`vo=gpu`/`mediacodec_embed`, `hwdec=mediacodec`).
- **Routing.** ExoPlayer first for everything. Fall back to mpv once on: a source error that isn't HTTP 4xx, the
  15 s load timeout, a renderer that can't decode the video or audio format (`MediaCodec` unsupported), or a stream
  with audio but no video track when it's ready (the HEVC-black-picture class of failures on Apple; on TV boxes
  usually codecs the box lacks). `EngineMemory` sends known failures straight to mpv next time.
- **Audio formats.** Media3's FFmpeg audio decoder extension (built LGPL-only) for AC-3/E-AC-3/DTS on boxes without
  them; passthrough to the TV/receiver when the device reports it supports the format.
- **Xtream live format.** Request `.ts` by default (ExoPlayer handles progressive TS well and it starts faster);
  fall back to `.m3u8` on failure. This differs from Apple (which requests HLS for AVFoundation) on purpose.
- **libmpv.** An LGPL build (`-Dgpl=false`, FFmpeg without GPL parts), arm64-v8a and armeabi-v7a (many TV boxes run
  32-bit userlands) and x86_64 for the emulator. Whether to build it from mpv-android's build scripts in CI-free
  form or use an existing LGPL AAR is the builder's call; it must be reproducible and listed in Acknowledgements.
- **Behaviours carried over:** quick reopen of a just-closed title (`PlayerSlot.park`, 2 minutes), immediate seek
  feedback (`seekGoal`), loading shown in the play button (no text), failover/reconnect messages, Up Next countdown
  (Off/5–30 s), Skip Intro / Skip Credits, keep the screen on while playing.

### Remote mapping in the player

The full key table (every `KeyEvent`, live vs on-demand) is in Appendix C → "Remote control in the player".
In short: OK toggles the chrome, Left/Right seek on-demand content only, Up opens info and tracks, Down opens the
channel or episodes strip, channel up/down zaps or changes episode, Back steps out, Guide opens Live TV.

## Screens

Left navigation drawer (Compose for TV `NavigationDrawer`, collapsed to icons, expands on focus): **Search, Home,
Live TV, Movies, TV Shows, Favorites, Settings.** Back from a section's top page returns focus to the drawer; Back
from the drawer exits the app (with no confirmation dialog, per Google's TV guidelines).

- **Home:** hero (rotating artwork of featured titles, focusable Play/More buttons), then rows: Continue Watching,
  Up Next, On Now, Recently Added, Top Rated, Favorites — as on Apple.
- **Live TV:** live preview (16:9, top) with now/next, category chips, the guide grid below (sticky time ruler and
  channel column, now-line, catchup markers). D-pad moves through programmes; OK on a current programme tunes,
  on a past one with catchup plays it from the archive.
- **Movies / TV Shows:** category menus (`CategoryGrouping`), pinned categories as chips, poster grid; detail page
  with backdrop, title logo, Play/Resume, seasons and episode rows with progress, mark watched.
- **Search:** text field with the on-screen keyboard and a mic button (in-app voice through `SpeechRecognizer`/
  `RecognizerIntent`), results for channels, what's on, movies and shows, recent searches.
- **Settings:** Playlists (add, edit, refresh, remove), Guide (extra XMLTV feeds, time shift), Playback (engine
  preference, Up Next countdown, resume), Metadata (Cinemeta / TMDB key, episode pictures), Appearance (category
  names: Automatic / Arabic / Original, `categoryNameStyle`), About (version, licences, "you're responsible for your playlists").
- **First run:** Welcome screen with "Add a playlist" (QR setup) as the main action.

Visual style: the Apple apps' layout and hierarchy (hero, shelves, glass-like player chrome, accent colour), drawn
with TV Material components and Google TV focus conventions (scale + glow on the focused card, no hover). Focus must
always be visible and land somewhere sensible on every screen change.

## Adding a playlist from a phone (QR setup)

Typing URLs and passwords with a remote is the worst part of IPTV apps on TV.

1. "Add a playlist" shows a QR code and a short URL (`http://<tv-ip>:<port>/<token>`) plus a "type it here instead"
   option (on-screen keyboard form).
2. While that screen is open, the app runs a small HTTP server on the local network (Ktor CIO or NanoHTTPD). The
   page has the same fields as the Apple source editor (type: M3U URL / Xtream / Stalker; URL, username, password,
   MAC, guide URL, name).
3. A random one-time token in the path is required; it expires after one submission or 10 minutes, and the server
   stops when the screen closes. The TV shows what arrived and asks to confirm before saving.
4. Credentials go phone → TV over the home network only, never through a cloud service. The page is plain HTTP on
   the LAN (a self-signed certificate would scare users with browser warnings); the token limits who can submit.
   This trade-off is noted in the README.

## Google TV integration

- **Watch Next:** publish Continue Watching entries and next episodes as `WatchNextProgram`s (`androidx.tvprovider`)
  so they appear in Google TV's "Continue watching" row; update on progress changes, remove when finished or
  cleared. Deep links open the title and resume.
- **Media session** for Assistant and remote media keys.
- **Banner and launcher icon** (320×180 banner required for TV launchers).
- Not in v1: preview channels on the home screen, global search provider.

## Performance targets

Measured in release builds on the owner's TCL Google TV (the emulator only for quick checks):

- M3U with 100k entries: parse + store under 15 s; memory stays bounded (no full-file string).
- XMLTV with 1M programmes (gzip): ingest under 60 s, streaming; programmes outside −1 day … +7 days are skipped.
- Guide grid scrolls at 60 fps on the emulator with 2,000 channels; rows are lazy, programmes paged by time window.
- First frame of a live TS channel from the test kit: under 2 s on the emulator.

## Testing

- `core`: JVM unit tests (JUnit 5 + kotlin.test), including the parity cases and shared fixtures. Run by
  `android/scripts/check-build.sh`, which also assembles the app.
- `data`/`player`: Robolectric or instrumented tests where they add value (Room migrations, routing decisions with a
  fake engine).
- End to end: the Google TV emulator against the test kit (`python3 scripts/testkit/server.py`; the emulator reaches
  the Mac's `127.0.0.1:8765` as `10.0.2.2:8765`). The TCL TV needs the server on the LAN: `server.py` already
  has `--host` / `TESTKIT_HOST` (default 127.0.0.1), so run `TESTKIT_HOST=0.0.0.0 python3 scripts/testkit/server.py`.
- Player verification (decoder fallback, passthrough, first-frame time) happens on the TCL; a phase isn't done
  until it has passed there. The owner's own copy of the app and their real playlists on that TV are never touched:
  test builds use the applicationId suffix `.scratch` so they install alongside, and are uninstalled afterwards.
- Screenshots for README/Play come from the test kit only.
- Never against the maintainer's real playlists.

## Phases

1. **Skeleton:** parity tooling first (hook, `PARITY_BASE`, backlog script, vector harness, `CLAUDE.md` rule) so
   tagging starts at once; install the latest stable JDK with SDKMAN, Gradle wrapper (a version that supports it), modules, Compose for TV shell with the drawer and empty screens, Android SDK +
   emulator set up, `check-build.sh`, CI-free release build signed with a local debug key.
2. **Core port:** parsers, provider clients, models, stream resolution, with parity tests green.
3. **Data:** Room schema, playlist and guide ingest, refresh jobs, secret storage; benchmarks against the targets.
4. **Player:** engines, routing/failover, remote mapping, chrome, Up Next, Skip Intro, quick reopen.
5. **Screens:** Home, Live TV guide, Movies, TV Shows, details, Search, Settings, Welcome + QR setup.
6. **Google TV integration and polish:** Watch Next, media session, banner, focus audit, low-RAM tuning, metadata.
7. **Store:** Play listing (as Antenna), privacy policy (`docs/app-store/privacy.md` adapted), Data safety form,
   Acknowledgements/licences, screenshots from the test kit, docs (README → Google TV, `design.md`, `testing.md`,
   `CLAUDE.md`).

Progress and deferred items: `docs/android-roadmap.md`.

## Left to the builder

- How libmpv is produced (build from mpv-android scripts vs an existing LGPL AAR), as long as it's LGPL and
  reproducible.
- Room vs raw SQLite for hot paths, decided by the benchmarks above.
- Exact Compose for TV components, animation details, and the module boundaries inside `data`/`player`.
- Which HTTP server library runs the QR setup page.
- Play signing setup (the upload key belongs to the maintainer; the builder never creates or handles release keys,
  only debug keys).
