# Tuner — native macOS IPTV player (design)

Date: 2026-10-01. Goal: a native macOS counterpart of ynotv (see `ynotv-reference.md`) covering its core
IPTV experience — sources, guide, live TV, VOD, catchup, multiview, DVR, reminders — built only with
Apple frameworks plus SQLite and libmpv.

## Decisions

| Concern | Decision | Why |
|---|---|---|
| UI | SwiftUI + AppKit (NSViewRepresentable for video) | Native look, materials, menus, keyboard handling, fullscreen |
| Build | Swift Package Manager + `scripts/build-app.sh` bundling a `.app` | Only Command Line Tools are installed (no Xcode) |
| Language mode | Swift 6 for `TunerCore`; Swift 5 for the app target | Strict concurrency where it is cheap; no runtime isolation traps in C-callback-heavy player code |
| Persistence | SQLite via GRDB 7 (WAL) | Playlists reach 100k+ rows and guides millions; SwiftData macros are unavailable without Xcode and too slow at this size |
| Playback | `PlaybackEngine` protocol, **AVFoundation first** (AVPlayerLayer: native HLS, PiP, AirPlay); **libmpv** (render API → CAOpenGLLayer) only as an automatic fallback for what AVFoundation can't open | "Fully native" requirement; but raw MPEG-TS/MKV — common in IPTV — need mpv. Xtream live is requested as HLS so AVPlayer handles it |
| libmpv linkage | `dlopen` at runtime from the app bundle, `/opt/homebrew/lib`, `/usr/local/lib` | The app builds and runs without mpv; no install-name rewriting for development |
| DVR | `ffmpeg -c copy` subprocess (`Process`) | Same as ynotv; remux without re-encoding |
| Notifications | UserNotifications | Native reminders |
| Credentials | Stored in the app's SQLite database (0600, Application Support) | Keychain prompts on every ad-hoc re-sign during development; revisit for a signed release |

### SDK workarounds (macOS 27 SDK with Command Line Tools only)

- SwiftUI's `@State` resolves to a macro whose plugin ships only with Xcode. The app uses
  `typealias ViewState<V> = SwiftUI.State<V>` and writes `@ViewState`; `@Entry` is avoided (manual `EnvironmentKey`).
- Swift Testing's macro plugin lives in `…/host/plugins/testing`; `scripts/test.sh` passes `-plugin-path`.

### Engine routing and fallback (PlayerSlot)

- Route by URL: `.m3u8`/MP4/MOV → AVFoundation; raw TS, MKV, non-HTTP schemes → mpv. Errors and the 15 s load
  timeout fall back to the other engine once (not for HTTP 4xx, which another decoder can't fix).
- **Silent audio-only**: AVFoundation drops video it can't decode *without an error*. Common case: HEVC in
  MPEG-TS HLS segments (Apple only allows HEVC in fMP4), e.g. many "HEVC"/"4K" sports channels. The result is a
  black picture with sound. `AVEngine` checks `AVPlayerItem.tracks` at `readyToPlay`: audio but no video means it
  holds playback for up to 1.5 s, then sends `.videoUnsupported`. Healthy streams list their video track by
  `readyToPlay`. `PlayerSlot` reopens the stream in mpv (when the engine preference is Automatic) and remembers the
  channel for the session, so re-tuning goes straight to mpv and AirPlay uses the bridge for it.
- **AirPlay bridge** (`AirPlayBridge`): ffmpeg `-c copy` re-wraps a stream AirPlay can't take into LAN HLS
  (H.264 → TS segments; HEVC → fMP4 + `hvc1` tag + `aac_adtstoasc`. Without that filter, ADTS AAC from TS fails
  with a misleading EPERM). It runs under a `/bin/sh` watchdog that stops ffmpeg when the app's PID disappears
  (crash or force-quit), because macOS has no parent-death signal and an orphan would hold the provider connection.

### Episodes, Up Next, ratings, trailers

- `EpisodeNavigation` (TunerCore, tested) orders episodes by season/number for ⏮/⏭, media keys and autoplay; specials
  (season 0) are only stepped through while watching one. `AppModel.episodeContext` holds the playing show's episodes.
- `UpNextCountdown` (tested) shows the card for the last N seconds, driven by the real time left, so it pauses with the
  video; at zero the episode has ended and the existing autoplay starts the next one unless the user cancelled it.
- `IMDbRatingsService` (TunerCore, tested) streams IMDb's `title.episode` / `title.ratings` data sets (gzip, byte-level
  scan, ≈0.5 s per show in release) and caches per-show results in SQLite (migration v4). Cinemeta's per-episode
  `rating` is *not* IMDb's (e.g. Breaking Bad S1E1: Cinemeta 7.7 vs IMDb 9.1) and is never shown as IMDb.
- Trailers: `TrailerOverlay` (WKWebView + YouTube IFrame API with an https bundle-id base URL — YouTube refuses embeds
  without one, error 153 — or AVKit for direct links). While a trailer is open, single-key shortcuts are suspended.

## Architecture

```
Sources/
  CMPV/        libmpv headers (vendored, ISC) + runtime loader: dlopen + forwarding of ~30 mpv_* functions
  CZlib/       gzip via the system zlib (gzread handles multi-member files)
  TunerCore/   (no UI, Swift 6 strict concurrency, unit-tested)
    Models/        Source, Channel, Category, Program, EPGFeed/EPGChannel, Movie/Series/Episode, WatchProgress,
                   Reminder, Recording, CustomGroup
    Parsing/       M3UParser (byte-level), XMLTVParser (byte scanner over mmap), Gzip, ChannelNameNormalizer,
                   StableID, CatchupURLBuilder, TitleParser
    Networking/    HTTPClient, LenientJSON
    Providers/     XtreamClient, StalkerClient (actor)
    Database/      AppDatabase (migrations), Records, +Library (sync writes), +Queries, +User (prefs, progress…)
    Services/      SyncService (actor), GuideService (actor: ingest + key resolution), StreamResolver (actor),
                   RecordingService (actor, ffmpeg), M3UExporter
  Tuner/       (SwiftUI app, Swift 5 mode)
    App/           TunerApp, AppModel (@Observable root + actions + background loops), Preferences, Navigation,
                   RootView (sidebar shell + window-level player), KeyboardShortcuts + menu commands
    Player/        PlaybackEngine, AVEngine (primary), MPVEngine + MPVVideoLayer (fallback), PlayerSlot (routing,
                   watchdog, failover, progress), PlayerManager (4 slots, layouts), SlotVideoView, PlaybackItem
    Views/         Live/ (guide), VOD/ (Home, Movies, TV Shows, details, Search), Player/ (presentation,
                   chrome, multiview, mini), Settings/ (settings, source editor, welcome), Recordings/, Common/
```

Data flow: views call `AppModel` actions and read `model.db` in `.task(id:)` blocks keyed on
`libraryRevision` / `guideRevision` / `userRevision`, which `AppModel` bumps (debounced) from GRDB
`DatabaseRegionObservation`. Syncs run in `SyncService` off the main thread and write in single transactions.

## Data model (SQLite)

- `source` — config + sync status (counts, expiry, connections, error, timestamps, discovered guide URL).
- `category(kind live|movie|series)`, `channel`, `movie`, `series`, `episode` — provider data, **fully replaced
  per source in one transaction** on each sync (resolved guide keys are carried over so the guide doesn't blank).
- `channelPref`, `categoryPref` — user state (favourite, order, hidden, alias, EPG override) keyed by the stable
  id, stored separately so it survives a channel vanishing for one sync.
- `epgFeed`, `epgChannel(key = feedId|xmltvId)`, `program(epgKey, start, end, …)`. `channel.epgKey` is resolved
  after each guide ingest: override → Stalker native → tvg-id → normalised name; preferring keys with programmes,
  then the channel's own source feeds, then global feeds, then other sources' feeds.
- `watchProgress`, `vodFavorite`, `history` (recent channels), `customGroup(+Member)`, `reminder`, `recording`.
- Failover candidates are computed on demand (same EPG key, tvg-id or normalised name) instead of curated groups.

## UX — Apple TV app style (user requirement: "fully native, experience like the Apple TV app")

- Native `NavigationSplitView` sidebar: Search · Home · Live TV · Movies · TV Shows · Recordings, then
  "Channels" (Favorites, Recently Watched, custom groups).
- Home: rotating hero artwork + shelves (Continue Watching, On Now, Recently Added, Top Rated, Favorites).
- Movies / TV Shows: category chips + poster grid; detail pages with backdrop hero, capsule Play/Resume, seasons
  and episode cards with progress; autoplay of the next episode.
- Live TV: 16:9 live preview + now/next header, category chips + source picker, guide grid (sticky ruler and
  channel column, now-line, catchup/reminder/recording markers), channel context menu.
- Player: one persistent video view per slot that moves between **full window** (sidebar collapses, TV-app glass
  controls that auto-hide), the guide **preview**, and a **mini player** while browsing — never recreated.
  Multiview: single / PiP / main + 3 / 2×2; clicking a cell promotes it (audio follows).
- Settings window (⌘,): Playlists (+ global guide feeds), Playback, Guide & Library, Recording, Appearance,
  Shortcuts, About. First run: Welcome screen with source cards.

### How the player is hosted (learned during integration testing)
- `PlayerHost` is an overlay on the **whole `NavigationSplitView`** in `RootView`. On macOS each split-view column
  and each `NavigationStack` destination is a separate AppKit hosting view; an overlay inside the detail column
  is covered by pushed detail pages.
- The Live TV preview slot reports its rect in **window coordinates** via a tiny AppKit probe
  (`.playerPreviewSlot()`, refreshed per display frame); SwiftUI preferences can't cross hosting boundaries.
- Embedded AppKit views ignore SwiftUI `opacity`/`zIndex`, and SwiftUI `clipShape`/`shadow` decorations at the
  video's rect render above them. So idle slots are parked as 1×1 rects off-stage; corners and the mini-player
  shadow are Core Animation properties on `VideoContainerView`; and engine-view ownership is window-aware.
- No SwiftUI hover region over the stage (it swallows clicks beneath); full-window pointer tracking uses an
  `NSEvent` monitor.

## Improvements over ynotv

Per-channel `#EXTVLCOPT` user-agent/referrer, URL-encoded credentials, commas in titles, M3U VOD grouping,
user state that survives resyncs, failed syncs retried and errors cleared on success, native-first engine routing
(`.m3u8` for AVFoundation, `.ts`/MKV to mpv), no wasted second connection on definitive HTTP errors, multiview
connection-limit warning, empty-guide detection with guidance.

## Testing

- `scripts/test.sh` — 42 Swift Testing tests for `TunerCore` (parsers, gzip, catchup URLs, Xtream/Stalker helpers,
  normalisation, title parsing, database semantics, guide key resolution).
- `scripts/testkit/` + `docs/testing.md` — local mock providers (M3U + XMLTV, Xtream panel, live TS/HLS, dead and
  flaky channels, multi-track VOD) used for end-to-end UI testing of the built app.
- Verified on a real Xtream account: 11,950 channels / 41,080 movies / 15,030 series synced in 25 s.
