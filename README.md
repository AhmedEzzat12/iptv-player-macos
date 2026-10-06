# Tuner

A native macOS IPTV player with an Apple TV app–style experience — SwiftUI + AppKit + AVFoundation,
modelled on the feature set of [ynotv](https://github.com/tbeezy/ynotv) (see `docs/ynotv-reference.md`).

![Tuner demo: live guide, player, multiview, downloads, episodes and Up Next, search and updates](docs/media/tuner-demo.gif)

▶︎ Full demo video (61 s, 1600×1008): [`docs/media/tuner-demo.mp4`](docs/media/tuner-demo.mp4)

| Home | Live TV guide with preview |
|---|---|
| ![Home](docs/media/01-home.png) | ![Live TV guide](docs/media/02-live-guide.png) |
| **Player** | **Multiview (2×2)** |
| ![Player](docs/media/03-player.png) | ![Multiview](docs/media/04-multiview.png) |
| **Movies with the mini player** | **Movie details** |
| ![Movies and mini player](docs/media/05-movies-miniplayer.png) | ![Movie details](docs/media/06-movie-detail.png) |
| **TV show with seasons** | **Search: channels and what's on** |
| ![Series](docs/media/07-series-detail.png) | ![Search](docs/media/08-search.png) |
| **Downloads for offline viewing** | **Episodes in the player** |
| ![Downloads](docs/media/11-downloads.png) | ![Episodes panel](docs/media/12-player-episodes.png) |
| **Up Next countdown** | **Automatic updates** |
| ![Up Next](docs/media/13-up-next.png) | ![Update available](docs/media/14-update.png) |
| **Settings → Shortcuts** | **Settings → Metadata** |
| ![Shortcuts](docs/media/09-settings-shortcuts.png) | ![Metadata](docs/media/10-settings-metadata.png) |

<sub>Screenshots and video use the local test kit (`scripts/testkit`): synthetic channels and titles, plus four
Blender Foundation open movies (CC BY). No provider content is shown.</sub>

- **Sources:** M3U/M3U8 playlists (URL or file, gzip), Xtream Codes, Stalker/MAG portals; backup server URLs.
- **Live TV:** Apple-styled guide grid with live preview, categories, favourites, custom groups, recently watched,
  channel zapping, catchup/timeshift (Xtream, Flussonic, append/shift and `catchup-source` templates, Stalker).
- **Guide:** XMLTV (gzip, multi-member), provider guides (Xtream `xmltv.php`, M3U `url-tvg`, Stalker), extra and
  global feeds, automatic matching by tvg-id or normalised name, per-source time shift, programme search, reminders
  with auto-switch.
- **Movies & TV Shows:** browsing with posters, details, seasons/episodes, resume and Continue Watching. Each page
  shows the playlist's own title (also under a title logo from online metadata) and where it's listed
  (Playlist › Category). Trailers
  play inside the app (YouTube's official embedded player, or Apple's player for direct links).
- **Episodes in the player:** ⏮/⏭ previous/next episode (across seasons; ⌘⇧←/→), an Episodes panel to jump to any
  episode with its picture, progress and **IMDb rating**, and a Netflix-style "Up Next" countdown (Off/5–30 s in
  Settings → Playback) with Play Now and Cancel. Episode ratings come from IMDb's public data sets (≈64 MB, downloaded
  on first use and refreshed weekly; Cinemeta's episode ratings aren't IMDb's).
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
- **Multiview:** single, picture-in-picture, main + 3, 2×2.
- **AirPlay:** send video to an Apple TV or AirPlay display from the player's top bar. Streams that were opened
  with mpv are reopened in Apple's player automatically when their format allows (Xtream live via HLS, MP4,
  HLS). Formats AirPlay can't take directly (MKV, raw TS, HEVC in TS) are re-wrapped on the Mac by ffmpeg
  (`-c copy`, no quality loss) into HLS served on the local network.
- **HEVC channels:** streams whose video Apple's player can't decode (HEVC in MPEG-TS HLS plays as sound only)
  are detected and reopened in mpv automatically, instead of showing a black picture.
- **Online metadata:** Cinemeta (no account) or TMDB (your API key) adds title logos, backdrops, cast, ratings,
  trailers and episode pictures; episode pictures can be shown, blurred until watched, or hidden.
- **Keyboard & media keys:** single-key shortcuts in the player (Space, ←/→ seek, ↑/↓ volume, Page Up/Down channels, M, F, Esc…), all remappable in
  Settings → Shortcuts (`/` shows the current keys); ⌘ equivalents in the menu bar; hardware media keys,
  AirPods and Control Center's Now Playing control playback (next/previous = channel zap for live TV, next
  episode for shows).
- **Recordings:** record now or schedule from the guide (ffmpeg stream copy).

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

- macOS 15 or later (Liquid Glass on macOS 26+), Apple silicon or Intel.
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
```

`docs/testing.md` describes the local test kit: synthetic channels, a mock Xtream server and a live guide.

## Releasing

Releases are built and published from your Mac with the GitHub CLI (`brew install gh && gh auth login`):

```bash
# bump VERSION, commit and push, then:
scripts/release.sh
```

It runs the tests, builds the app (version from `VERSION`, build number = commit count), signs the update with your
Sparkle key, writes `appcast.xml` and creates GitHub release `v<version>` with `Tuner.zip` and the appcast.
Installed copies check `releases/latest/download/appcast.xml` daily and offer the update.

- The signing key lives in your login keychain. The first run creates it (Keychain may ask); Soonbar uses the same
  key. **Back it up once** — without it, installed copies can't verify future updates:
  `"$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)/generate_keys" -x ~/sparkle-private-key.txt`,
  then move that file into a password manager.
- The repository must be public for installed copies to download updates.

## Layout

| Path | What |
|---|---|
| `Sources/TunerCore` | UI-free core: models, M3U/XMLTV parsers, Xtream/Stalker clients, SQLite (GRDB), sync, guide, stream resolution, DVR |
| `Sources/Tuner` | The SwiftUI app: app model, player engines and controller, views |
| `Sources/CMPV` | libmpv headers + runtime loader (libmpv is `dlopen`ed, never linked) |
| `Sources/CZlib` | gzip via the system zlib |
| `docs/` | Design, ynotv reference notes, testing guide |

Data lives in `~/Library/Application Support/Tuner/` (SQLite). Recordings default to `~/Movies/Tuner Recordings`,
downloads to `~/Movies/Tuner Downloads`.

Tuner is a media player only; it does not provide any channels or content. Automatic updates use
[Sparkle](https://github.com/sparkle-project/Sparkle) (MIT-style license).
