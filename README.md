# Tuner

A native IPTV player for **Mac, iPhone and iPad** with an Apple TV app–style experience — SwiftUI + AVFoundation
(+ AppKit on the Mac), modelled on the feature set of [ynotv](https://github.com/tbeezy/ynotv)
(see `docs/ynotv-reference.md`). One codebase: the iPhone/iPad app compiles the Mac app's sources
(see [iPhone and iPad](#iphone-and-ipad)).

![Tuner demo: live guide, player, downloads, episodes and Up Next, search and updates](docs/media/tuner-demo.gif)

▶︎ Full demo video (61 s, 1600×1008): [`docs/media/tuner-demo.mp4`](docs/media/tuner-demo.mp4)

| Home | Live TV guide with preview |
|---|---|
| ![Home](docs/media/01-home.png) | ![Live TV guide](docs/media/02-live-guide.png) |
| **Player** | **Movies with the mini player** |
| ![Player](docs/media/03-player.png) | ![Movies and mini player](docs/media/05-movies-miniplayer.png) |
| **Movie details** | **TV show with seasons** |
| ![Movie details](docs/media/06-movie-detail.png) | ![Series](docs/media/07-series-detail.png) |
| **Search: channels and what's on** | **Downloads for offline viewing** |
| ![Search](docs/media/08-search.png) | ![Downloads](docs/media/11-downloads.png) |
| **Episodes in the player** | **Up Next countdown** |
| ![Episodes panel](docs/media/12-player-episodes.png) | ![Up Next](docs/media/13-up-next.png) |
| **Automatic updates** | **Settings → Shortcuts** |
| ![Update available](docs/media/14-update.png) | ![Shortcuts](docs/media/09-settings-shortcuts.png) |
| **Settings → Metadata** | **Settings → AI (each off until you turn it on)** |
| ![Metadata](docs/media/10-settings-metadata.png) | ![AI settings](docs/media/15-settings-ai.png) |
| **Search that understands phrases** | **iPhone player** |
| ![Search with understood filters](docs/media/16-search-understood.png) | ![iPhone player](docs/media/17-iphone-player.png) |
| **iPhone player in landscape** | **Top 10 on Home (iPhone)** |
| ![iPhone player in landscape](docs/media/18-iphone-player-landscape.png) | ![Top 10 rows](docs/media/19-top10.png) |
| **Mark a season or show as watched** | **iCloud Sync (iPhone)** |
| ![Season menu](docs/media/20-season-watched.png) | ![iCloud Sync settings](docs/media/21-icloud-sync.png) |
| **Up Next on Home** | **Pull down to sync or refresh (iPhone)** |
| ![Up Next row](docs/media/22-up-next.png) | ![Pull to refresh hint](docs/media/23-pull-to-sync.png) |

<sub>Screenshots and video use the local test kit (`scripts/testkit`): synthetic channels and titles, plus four
Blender Foundation open movies (CC BY). No provider content is shown.</sub>

- **Sources:** M3U/M3U8 playlists (URL or file, gzip), Xtream Codes, Stalker/MAG portals; backup server URLs.
- **Live TV:** Apple-styled guide grid with live preview, categories, favourites, custom groups, recently watched,
  channel zapping, catchup/timeshift (Xtream, Flussonic, append/shift and `catchup-source` templates, Stalker).
- **Guide:** XMLTV (gzip, multi-member), provider guides (Xtream `xmltv.php`, M3U `url-tvg`, Stalker), extra and
  global feeds, automatic matching by tvg-id or normalised name, per-source time shift, programme search, reminders
  with auto-switch.
- **Movies & TV Shows:** browsing with posters, details, seasons/episodes, resume and Continue Watching, plus an
  **Up Next** row on Home with the next episode of each show you're watching (the one after an episode you finished).
  Providers' long category lists are grouped into a few menus — Featured, Languages & Countries, Platforms, Genres,
  By Year, Sports, Kids, Quality, More — read from English and Arabic category names. Pin the categories you use
  (they become chips), hide the rest, and choose whether names show their English part, their Arabic part or the
  provider's full name (Categories next to the page title). Each page
  shows the playlist's own title (also under a title logo from online metadata) and where it's listed
  (Playlist › Category). Trailers
  play inside the app (YouTube's official embedded player, or Apple's player for direct links).
- **Watched state for shows:** mark an episode watched or unwatched from its card (Tuner offers to mark the earlier
  ones too), a whole season from the "…" beside Download Season, or the whole show from the "…" next to Play
  (asks first).
- **Episodes in the player:** ⏮/⏭ previous/next episode (across seasons; ⌘⇧←/→), an Episodes panel to jump to any
  episode with its picture, progress and **IMDb rating**, and a Netflix-style "Up Next" countdown (Off/5–30 s in
  Settings → Playback) with Play Now and Cancel. Episode ratings come from IMDb's public data sets (≈64 MB, downloaded
  on first use and refreshed weekly; Cinemeta's episode ratings aren't IMDb's).
- **Skip Intro / Skip Credits:** while a known intro, recap or end credits play, a Netflix-style button appears
  bottom-right (K on the Mac); credits of an episode go straight to the next one. The times come from chapter
  markers in the video, from the free crowd-sourced [TheIntroDB](https://theintrodb.org) and
  [IntroDB](https://introdb.app) (only the title's IMDb or TMDB id and season/episode number are sent, and only while
  online lookups are on in Settings → Metadata), and from your own skipping: skip the same stretch early in two
  episodes of a show and later episodes offer it. They show as brighter stretches on the timeline. Settings →
  Playback → "Skip intro and credits": Show button (default), Skip automatically (with Undo; credits only into a
  next episode, learned intros only once you've used their button twice), or Off.
- **Downloads & offline:** download a movie, an episode or a whole season (Downloads in the sidebar, ⌘6) and
  watch it without a connection: a downloaded title always plays from the Mac. Downloads run one at a time in watch
  order, resume where they stopped (after a pause, a lost connection or a relaunch), and pause automatically while
  you stream from an account that allows a single connection. Files are saved as
  `Movies/<Title> (<Year>).<ext>` and `TV Shows/<Show>/Season N/<Show> - S01E03 - <Title>.<ext>` in
  `~/Movies/Tuner Downloads` (Settings → Downloads), so other players can open them too.
- **Automatic updates:** releases from GitHub install themselves with [Sparkle](https://sparkle-project.org)
  (Tuner → Check for Updates…, Settings → About). Each update is signed (EdDSA) and verified before it's installed.
- **Player:** AVFoundation first (HLS, MP4; PiP, AirPlay), automatic libmpv fallback for raw MPEG-TS/MKV and
  other formats; stall watchdog with failover to duplicate channels and reconnect; audio/subtitle tracks; stats.
- **AirPlay:** send video to an Apple TV or AirPlay display from the player's top bar. Streams that were opened
  with mpv are reopened in Apple's player automatically when their format allows (Xtream live via HLS, MP4,
  HLS). Formats AirPlay can't take directly (MKV, raw TS, HEVC in TS) are re-wrapped on the Mac by ffmpeg
  (`-c copy`, no quality loss) into HLS served on the local network.
- **HEVC channels:** streams whose video Apple's player can't decode (HEVC in MPEG-TS HLS plays as sound only)
  are detected and reopened in mpv automatically, instead of showing a black picture.
- **Audio enhancements** (player Audio menu, or Settings → Playback → Audio; off by default): **Dialogue Boost**
  (clearer, louder speech: centre channel raised, speech band lifted, rumble cut), **Night Mode** (reduces loud
  sounds and raises quiet ones) and **Volume Levelling** (evens out loudness between channels and titles). They
  apply live, without restarting the stream. Apple's player can't process HLS sound, so while one is on, HLS
  streams play with mpv (Automatic engine) and lose Picture in Picture and native AirPlay until it's off again.
- **Sleep timer** (Audio menu): 15/30/45/60/90 minutes or the end of the episode or movie (live TV: the end of
  the programme), with the time left in the menu. The sound fades out over the last 10 seconds; movies pause,
  live TV stops, and no next episode starts. Stopping playback cancels it; it's never remembered.
- **Online metadata:** Cinemeta (no account) or TMDB (your API key) adds title logos, backdrops, cast, ratings,
  trailers and episode pictures; episode pictures can be shown, blurred until watched, or hidden.
- **Keyboard & media keys:** single-key shortcuts in the player (Space, ←/→ seek, ↑/↓ volume, Page Up/Down channels, M, F, Esc…), all remappable in
  Settings → Shortcuts (`/` shows the current keys); ⌘ equivalents in the menu bar; hardware media keys,
  AirPods and Control Center's Now Playing control playback (next/previous = channel zap for live TV, next
  episode for shows).
- **Search:** channels, what's on TV, movies and shows across all playlists; recent searches are kept (the ones you
  pressed Return on, opened or played) and shown while the field is empty. ⌘F on the Mac, or tapping the Search tab
  again on iPhone/iPad, puts the cursor in the field.
- **Recordings (Mac):** record now or schedule from the guide (ffmpeg stream copy).
- **On-device AI features** (Settings → AI, each off until you turn it on; nothing about your library or what
  you watch leaves the device):
  - **Smart guide matching:** channels the guide doesn't list by ID or exact name get the guide channel with the
    closest name, ignoring tags like HD/FHD/4K, VIP and backup markers and prefixes like `UK:` or `|AR|`, and
    comparing Arabic and Latin names. Numbers and +1 timeshifts must agree (beIN Sports 1 never gets beIN
    Sports 2), near-ties are skipped, and a guide chosen by hand always wins.
  - **Recommendations:** "More Like This" on movie and show pages and up to two "Because You Watched …" rows on
    Home, worked out on this device from genres, cast, directors, categories, titles and plots in English and
    Arabic. Rows are seeded by what you finished or mostly watched and by your favourites; hidden categories (and
    adult ones when adult content is hidden) are never recommended.
  - **Understand natural searches:** "90s comedy series", "top rated Korean dramas", "Arabic movies since 2015",
    "مسلسلات تركية رومانسية" become filters for type, years, genre, language, 4K and rating, shown as chips you
    can tap off. Works offline in English and Arabic; with Apple Intelligence (OS 26+), Return on an English
    phrase the rules can't read also asks Apple's on-device model.
- **Top 10 on Home** (Settings → AI → Home, off by default): "Top 10 Movies" and "Top 10 TV Shows" rows with
  what's popular this week, showing only titles your playlists have, with its chart rank as a big number beside each poster (Netflix's own rank, so "1, 3, 4" when your library lacks number 2).
  The lists come from Netflix's public weekly Top 10 for your country (or worldwide), else TMDB trending (with your
  key) or Cinemeta's popular lists; titles are matched by IMDb/TMDB id or by cleaned name and year. Nothing about
  your library leaves the device. The country list is read once a week (up to ~30 MB, never on cellular or Low
  Data Mode); the others are small.
- **iCloud sync** (Settings → Sync, off by default): watch progress, favourites, custom groups, hidden and pinned
  categories, channel names and guide choices, recently watched channels, recent searches and settings follow you
  between your Macs, iPhone and iPad. Playlists come along without their passwords: an Xtream account (or an M3U
  link with a token) shows "Needs password" in Settings → Playlists until you enter it on that device. Each device
  keeps one small file in a folder in your iCloud Drive (on the Mac `iCloud Drive/Tuner Sync`; on iPhone/iPad you
  pick that folder once in Files); the newest change wins. Removing a playlist on one device leaves it on the others.
  Downloads, recordings, reminders and the guide stay on each device. The files are end-to-end encrypted only with
  Advanced Data Protection.
- **Artwork cache:** posters and backdrops are kept on disk (up to 600 MB, oldest out first) whatever the
  server's caching headers say, scaled to the size they're shown at, and kept in memory once loaded, so rows
  scroll smoothly and pictures appear at once when you come back.

## iPhone and iPad

The same app runs on iPhone and iPad (iOS/iPadOS 26+). It isn't on the App Store: you install it on your own
devices from Xcode, with a free Apple ID or a paid developer account.

**What's different on iPhone/iPad**

| | Mac | iPhone / iPad |
|---|---|---|
| Navigation | Sidebar | Tab bar (iPad: top bar that opens as a sidebar) |
| Live TV | Guide grid with preview | iPhone: channel list with now/next; iPad: guide grid |
| Player | Pointer-driven control panel, keyboard shortcuts | TV app–style touch layout (portrait and landscape): transport on the video, title and timeline below, Episodes / Next Episode pills; tap to show/hide, double-tap the sides to skip 10 s, swipe up for landscape, swipe down for portrait or to close; hardware volume |
| Refresh | Toolbar / ⌘R | Pull down on Home, Movies, TV Shows or Live TV: a short pull syncs with iCloud, a longer pull refreshes the playlists |
| Engines | AVFoundation, libmpv (Homebrew) fallback | AVFoundation, libmpv ([MPVKit](https://github.com/mpvkit/MPVKit)) fallback, built in |
| Picture in Picture | AVFoundation streams | AVFoundation streams (MKV and other mpv-only formats: no PiP) |
| AirPlay | All formats (ffmpeg re-wraps the rest) | AVFoundation streams; others via Screen Mirroring |
| Audio enhancements | All three on every stream with Homebrew's mpv (Audio menu in the control panel) | In the "…" menu. Dialogue Boost everywhere; Night Mode and Volume Levelling only for MP4/MOV in Apple's player (MPVKit's FFmpeg has no compressor or normaliser) |
| Recordings | Yes (ffmpeg) | No (iOS apps can't run ffmpeg) |
| Downloads | `~/Movies/Tuner Downloads` (choose in Settings) | Files › On My iPhone › Tuner › Downloads (not in iCloud backups) |
| iCloud sync | `iCloud Drive/Tuner Sync` (or a folder you choose) | Choose the same folder once in the Files picker |
| Updates | Automatic (Sparkle) | Reinstall from the checkout (below) |

Everything else — sources, sync, guide, metadata, categories, search, episodes and Up Next, downloads —
is the same code on both.

**Install on your iPhone/iPad** (needs Xcode 26+ with the iOS platform, and `brew install xcodegen`):

1. In Xcode → Settings → Accounts, sign in with your Apple ID. Note your team ID.
2. `cp iOS/Config/Local.xcconfig.example iOS/Config/Local.xcconfig`, then set your team ID (`DEVELOPMENT_TEAM`) and
   a bundle ID of your own (`TUNER_BUNDLE_ID`). The file is git-ignored.
3. Connect the device with a cable, unlock it and tap **Trust**. Turn on **Settings → Privacy & Security →
   Developer Mode** (the device restarts).
4. Run:
   ```bash
   iOS/scripts/install-device.sh
   ```
5. The first time, allow the app on the device: **Settings → General → VPN & Device Management** → your Apple ID →
   Trust.

With a **free Apple ID** the install expires after 7 days (your library and settings are kept): run the script
again before then, or install a login agent that does it for you. Every 3 hours it checks, and once the last install
is 4 days old it re-installs whatever is checked out, as soon as the device is reachable (plugged in, or on the
same Wi-Fi once paired; it may be locked). It waits while the sources have uncommitted changes, posts a notification
after each successful re-install, and from day 5 posts one if it still couldn't. Log: `~/Library/Logs/Tuner-iOS-resign.log`.

```bash
iOS/scripts/install-resign-agent.sh            # --remove to uninstall it
FORCE=1 iOS/scripts/resign-if-due.sh           # re-install now
```

To re-install from [Raycast](https://www.raycast.com), add the folder `iOS/scripts/raycast` in Raycast → Settings →
Extensions → Script Commands → Add Directories, then run **Reinstall Tuner on iPhone**. It notifies when it starts and
when it's done (or why it couldn't), and logs to the same file.

A paid Apple Developer Program membership makes installs last a year.

## Install

**Recommended** — one command in Terminal installs the latest release into Applications and opens it:

```bash
curl -fsSL https://raw.githubusercontent.com/AhmedEzzat12/iptv-player-macos/main/scripts/install-latest.sh | bash
```

Run the same command again any time to reinstall. After that the app updates itself (Tuner → Check for Updates…,
Settings → About). Optional: `brew install mpv` (MKV and raw MPEG-TS streams) and `brew install ffmpeg` (recordings).

**Or build from source** — for Macs where downloaded apps are blocked by an organization's profile, or to run
unreleased changes. Needs the Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/AhmedEzzat12/iptv-player-macos.git
cd iptv-player-macos
scripts/update-from-source.sh          # latest release
scripts/update-from-source.sh --main   # or: newest code on main
```

It builds in a temporary checkout (deleted afterwards, even on failure or Ctrl-C), replaces any installed copy, installs
the new build into `~/Applications` and opens it. Your library and settings are kept. Source builds don't update
themselves — run the script again to update.

**Or download manually:** get `Tuner.zip` from the [latest release](../../releases/latest), unzip it and move
`Tuner.app` to Applications. The first launch will be blocked — see below.

### "Tuner.app" Not Opened / "Apple could not verify…"

The app is free and open source but not notarized by Apple (that needs a paid developer account), so macOS blocks
copies downloaded in a browser. Any **one** of these fixes it, and you only need it once — updates installed by the
app itself aren't blocked:

1. **System Settings:** click **Done** on the warning, open **System Settings → Privacy & Security**, scroll to
   *Security*, click **Open Anyway** next to "Tuner.app was blocked", and confirm with your password.
2. **Terminal:** remove the download's quarantine flag, then open the app normally:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Tuner.app
   ```
3. **Reinstall with the one-command installer above** — `curl` downloads aren't quarantined, so the warning never
   appears.

## Requirements

- Mac: macOS 15 or later (Liquid Glass on macOS 26+), Apple silicon or Intel.
- iPhone/iPad: iOS/iPadOS 26 or later; building needs Xcode 26+ and XcodeGen (see above).
- Swift 6 toolchain (Command Line Tools are enough — Xcode is not required).
- Optional: `brew install mpv` (MPEG-TS/MKV playback) and `brew install ffmpeg` (recordings).

## Build & run

```bash
scripts/build-app.sh            # release build → build/Tuner.app
open build/Tuner.app
```

During development you can also `swift run Tuner`. Builds made this way don't update themselves (only release
builds carry the update-signing key).

## Test

```bash
scripts/test.sh                 # TunerCore unit tests (Swift Testing)
iOS/scripts/check-build.sh      # the iPhone/iPad app still compiles (Xcode + XcodeGen)
```

`docs/testing.md` describes the local test kit: synthetic channels, a mock Xtream server and a live guide.

## Releasing

One version for both apps: `VERSION` (e.g. `1.2.0`) is the marketing version of the Mac and the iPhone/iPad app,
and the build number of both is the commit count on `main`. A release is a tag `v<version>` on `main`.

1. Bump `VERSION` (patch for fixes, minor for features), commit on `main` and push.
   If the UI changed, add screenshots of it (and/or demo footage) to `docs/media/` and the gallery above in the
   same push. Capture them from the test kit only, never a real provider.
2. Publish the Mac release from your Mac with the GitHub CLI (`brew install gh && gh auth login`):
   ```bash
   RELEASE_MEDIA="docs/media/15-new-thing.png" scripts/release.sh
   ```
   `RELEASE_MEDIA` lists the new screenshots to attach to the GitHub release. If the views changed since the last
   release and no new pictures came with them, it stops and asks for them; `NO_RELEASE_MEDIA=1` releases anyway
   (for changes not worth a picture).
   It runs the tests, checks that the iPhone/iPad app still compiles (`SKIP_IOS_CHECK=1` skips that on a Mac
   without Xcode), builds the Mac app, signs the update with your Sparkle key, writes `appcast.xml` and creates
   GitHub release `v<version>` with `Tuner.zip` and the appcast. Installed Macs check
   `releases/latest/download/appcast.xml` daily and offer the update.
3. Update your iPhone/iPad from the same commit: `git pull && iOS/scripts/install-device.sh` (the login agent, if
   installed, installs whatever the checkout holds the next time it runs).

- The signing key lives in your login keychain. The first run creates it (Keychain may ask); Soonbar uses the same
  key. **Back it up once** — without it, installed copies can't verify future updates:
  `"$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)/generate_keys" -x ~/sparkle-private-key.txt`,
  then move that file into a password manager.
- The repository must be public for installed copies to download updates.

## Layout

| Path | What |
|---|---|
| `Sources/TunerCore` | UI-free core: models, M3U/XMLTV parsers, Xtream/Stalker clients, SQLite (GRDB), sync, guide, stream resolution, DVR, category grouping |
| `Sources/Tuner` | The SwiftUI app, shared by Mac and iPhone/iPad: app model, player engines and controller, views. Mac-only code is behind `#if os(macOS)`; iPhone layouts behind the `tunerCompact` environment flag |
| `iOS/` | The iPhone/iPad app: XcodeGen project (`project.yml`, builds `../Sources/Tuner`), iOS versions of the AppKit-only pieces (`Sources/`), signing config (`Config/`), install scripts (`scripts/`) |
| `Sources/CMPV` | libmpv headers + runtime loader (libmpv is `dlopen`ed, never linked) |
| `Sources/CZlib` | gzip via the system zlib |
| `docs/` | Design, ynotv reference notes, testing guide |

Data lives in `~/Library/Application Support/Tuner/` (SQLite; on iPhone/iPad in the app's own container). Recordings
default to `~/Movies/Tuner Recordings`, downloads to `~/Movies/Tuner Downloads` (iPhone/iPad: Files › Tuner ›
Downloads).

Tuner is a media player only; it does not provide any channels or content. Automatic updates use
[Sparkle](https://github.com/sparkle-project/Sparkle) (MIT-style license). The iPhone/iPad app bundles libmpv and
FFmpeg through [MPVKit](https://github.com/mpvkit/MPVKit) (GPL build; it's only installed on your own devices,
never distributed).
