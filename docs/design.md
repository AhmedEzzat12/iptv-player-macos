# Tuner — native macOS IPTV player (design)

Date: 2026-10-01. Goal: a native macOS counterpart of ynotv (see `ynotv-reference.md`) covering its core
IPTV experience — sources, guide, live TV, VOD, catchup, DVR, reminders — built only with
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
  `readyToPlay`. `PlayerSlot` reopens the stream in mpv (when the engine preference is Automatic) and remembers it
  (`EngineMemory`), so re-tuning goes straight to mpv and AirPlay uses the bridge for it.
- **Engine memory** (`EngineMemory`, UserDefaults, 30 days): a channel, movie or episode AVFoundation failed on
  (error, load timeout or no picture) starts in mpv next time, also after a relaunch; an episode also marks its
  show. Without it every relaunch paid for AVFoundation failing again (up to the 15 s timeout) before mpv started.
- **AirPlay bridge** (`AirPlayBridge`): ffmpeg `-c copy` re-wraps a stream AirPlay can't take into LAN HLS
  (H.264 → TS segments; HEVC → fMP4 + `hvc1` tag + `aac_adtstoasc`. Without that filter, ADTS AAC from TS fails
  with a misleading EPERM). It runs under a `/bin/sh` watchdog that stops ffmpeg when the app's PID disappears
  (crash or force-quit), because macOS has no parent-death signal and an orphan would hold the provider connection.

### Audio enhancements and sleep timer

Dialogue Boost, Night Mode and Volume Levelling are global preferences (`dialogueBoost`, `nightMode`,
`volumeLevelling`; device-specific, not synced), toggled from the player's Audio menu or Settings → Playback → Audio
and applied live through `PlaybackEngine.setAudioEnhancements`. Each engine reports what it actually applies
(`appliedAudioEnhancements`); the menu names enhancements that are on but can't apply to the current stream.

- **AVFoundation:** an `MTAudioProcessingTap` per audio track (`AudioTap`, `AVAudioMix` on the item, attached once an
  enhancement is on and the tracks are known; switching off only bypasses it) runs `AudioEnhancementProcessor`
  (TunerCore, tested): Dialogue Boost = mid/side with peaking EQ on the mid (−5 dB at 100 Hz, +4 dB at 2.5 kHz),
  mid ×1.12, side ×0.6, −2 dB headroom (mono/surround: the EQ per channel, since the tap doesn't know which channel is
  the centre); Volume Levelling = 3 s RMS towards −20 dBFS within ±12 dB, rising ≤ 2 dB/s and falling ≤ 6 dB/s, held
  below −55 dBFS; Night Mode = soft-knee compressor (−30 dBFS, 4:1, 9 dB knee, 5/200 ms, +9 dB makeup); then a
  −1 dBFS limiter. Realtime-safe: buffers allocated up front, settings in one atomic byte, no locks.
- **HLS can't be tapped** (checked on macOS 27.0.1 with a headless probe: a tap bound to an HLS item's audio track is
  never prepared or called; a tap without a track runs but only sees silence; the same code on an MP4 receives the
  real samples). So with the engine on Automatic, `PlayerSlot` opens HLS in mpv while an enhancement mpv can apply is
  on (Xtream live is then requested as TS), and reopens it in AVFoundation when they're all off (VOD at the same
  position). Trade-off: no native Picture in Picture or AirPlay for that stream meanwhile. AirPlay (which forces
  AVFoundation) and the AirPlay bridge win over enhancements. iOS 26 wasn't measured; the same behaviour is assumed.
- **mpv:** `MPVAudioFilterChain` (TunerCore, tested) builds labelled `af` entries (`@tuner-…:lavfi-<filter>=…`), set
  with `af remove` / `af add` so the user's own `af` from the advanced options stays. Separate entries, not one
  `lavfi=[graph]`: mpv rejects an unknown entry name when the option is set (keeping the old chain), but an unknown
  filter inside a graph only fails when audio starts, leaving no sound. The first mpv core probes which filters
  exist by setting each on the idle core. Dialogue: `pan` (downmix to stereo with the centre ×1.5, surrounds ×0.6;
  pan ignores absent channels, so one expression fits every layout), `dialoguenhance` + `aformat` when present, then
  the same `volume` + `equalizer` curve as above. Levelling: `speechnorm` (FFmpeg's "weak and slow" preset);
  `dynaudnorm` and `loudnorm` were rejected because their seconds of look-ahead made mpv drop seconds of audio
  whenever the chain changed. Night: `acompressor` with the same parameters as the tap. Homebrew's mpv 0.41 has
  them all; MPVKit 1.0.0 (iPhone/iPad) only has `pan`, `equalizer`, `volume`, `aformat` among them, so there mpv does
  Dialogue Boost only (and HLS moves to mpv only for it).
- **Sleep timer** (`SleepTimer`, TunerCore, tested; state in `PlayerSlot`, never persisted): minutes (wall clock, also
  while paused) or end of item (movie/episode: on the player's end event, with no autoplay and no Up Next card; live:
  when `currentProgram` ends). Over the last 10 s the slot's volume is scaled down linearly (the engines' volume curve
  makes that a perceptual fade); then VOD pauses (volume restored) and live stops. A manual stop cancels it.

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

### Skip Intro / Skip Credits

Segments (`SkipSegment`: recap, intro or credits, with start/end in seconds and their source) come from three
places, merged per kind by `SkipSegments.merge` (TunerCore, tested) in this order: **chapters → TheIntroDB → IntroDB →
learned**; each kind is taken from the first source that has a plausible segment of it.

- **Chapters** in the stream: AVFoundation's chapter metadata groups (MP4/MOV chapter tracks; chapters without a
  language — "und", as ffmpeg writes them — match no preferred language, so the first available locale is used) and
  mpv's `chapter-list`. `SkipSegments.classify` recognises short titles: Intro/Opening/OP/Main Titles/Theme,
  Recap/Previously/Summary, Credits/End Credits/Ending/ED/Outro/End Titles, Arabic مقدمة/شارة/تتر, ملخص/الحلقة
  السابقة, النهاية/شارة النهاية/تتر النهاية/الختام. Post-/mid-credits scenes, previews, "Cold Open", البداية and long
  titles are story. A chapter lasts until the next one; an intro chapter must start in the first 40 %, credits after
  60 %. Read 0.3 s after the engine reports `.loaded`, again at 3 s if there were none.
- **Online, keyless** (`SkipSegmentService`, actor), asked together when a movie or episode starts, never blocking
  playback (8 s timeout, no retries), and only while Settings → Metadata online lookups are on and the network is up.
  The ids come from the cached online metadata (IMDb id, else TMDB id); only those and the season/episode numbers are
  sent. Verified with real requests on 2026-10-30:
  - **TheIntroDB** — `GET https://api.theintrodb.org/v4/media?imdb_id=tt0944947&season=1&episode=1` (or `tmdb_id=`;
    no season/episode for movies) → `{"tvdb_id":121361,"type":"tv","season":1,"episode":1,"intro":[{"start_ms":435691,"end_ms":534851}],"credits":[{"start_ms":3631088,"end_ms":3697669}]}`.
    A null `start_ms` means 0, a null `end_ms` the end of the file; `recap` and `preview` arrays may appear (previews
    are ignored). Unknown title or episode → 404 (`media_not_found` / `episode_not_found`). OpenAPI at
    `theintrodb.org/openapi.yaml`: anonymous reads are limited to 30 requests per 10 s and 5,000 a day per IP (2,000 a
    day for one title). Free API; no terms of use are published beyond the documented limits.
  - **IntroDB** — `GET https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=1` (`&is_movie=true` for
    movies) → `{"intro":{"start_ms":437000,"end_ms":531000,…},"recap":null,"outro":{"start_ms":3631500,"end_ms":3699500,…},"post_credits":null,"no_intro":false,…}`;
    `outro` is the credits. An unknown title answers 200 with every segment null. Reads need no key and are rate
    limited (429; numbers not published). Its terms (`introdb.app/docs/terms`) allow integrating skip functionality in
    media players and ask for no bulk downloading; attribution is appreciated, not required.
  - Not used: AniSkip (`api.aniskip.com/v2/skip-times/{malId}/{episode}`, works keyless) needs MyAnimeList ids, which
    the app doesn't have.
  - Database timings describe a specific release, so `SkipSegments.sanitized` checks them against the playing file:
    an intro/recap lasts 5 s–5 min and ends in the first 25 % and the first 10 minutes; credits start in the last
    15 %; anything ending after the file's end (another cut, an offset encode) is dropped. TheIntroDB's `duration_ms`
    version matching isn't used (lookups start before the duration is known).
  - Cache: `skipSegmentCache` (migration `v8-skipSegments`), one row per movie/episode id with the raw segments of
    both databases (empty = not found): found 30 days, not found 7. A network failure caches nothing (unless the
    other database answered with times). Offline, or with lookups off, the cache is used as is.
- **Learned** (`SkipLearner`): a forward seek by the user (quick successive seeks joined by `ForwardSeekChain`, 3 s
  apart at most) that starts in the first 15 % of an episode and spans 20 s–3 min is stored in `skipLearnedSpan`
  (per show and episode, the newest replaces the older). When two episodes have spans agreeing within ±10 s at both
  ends, later episodes get their median as the show's intro, with the button only; pressing that button stores a
  confirmation, and after two confirmed episodes it can be skipped automatically.

Playback (`SkipController`, app target, main player only; `SkipTracker` in TunerCore holds the rules): the button
("Skip Intro", "Skip Recap", "Skip Credits", glass capsule at the Up Next card's spot) shows while the controls are up
and, with them hidden, for the first 6 s of a segment; the Up Next card replaces it. Intros/recaps seek to their end;
credits play the next episode (as Up Next would), or seek to the end of a movie or finale. Automatic mode skips each
segment once, with "Skipped intro · Undo" for 5 s; a segment the user seeks into or undoes is never skipped
automatically again, credits only when the next episode would autoplay anyway. The Mac shortcut is K (S is Search).
Segments are drawn on the scrubber. Logs give counts and status codes only.

### Downloads and offline

- `DownloadService` (TunerCore actor, tested) is a persistent queue in the `download` table (migration v5), one row per
  movie/episode id. It never stores stream URLs (Xtream URLs carry the password); each transfer resolves its URL through
  `StreamResolver` when it starts. One transfer at a time, FIFO by `createdAt`.
- `FileTransfer` gets its own `URLSession` per transfer, so cancelling really closes the provider connection, and writes
  the body on URLSession's delegate queue (never through the actor). Data goes to `<file>.part` and is renamed into place
  when complete. A part is resumed with `Range: bytes=<size of the .part>-` (206); a 200 restarts, a 416 either means
  "already complete" or starts over; a size change on the server also starts over. Redirects keep the User-Agent,
  Referer and Range headers (VOD URLs 302 to a CDN).
- Errors become words about what the provider did: 503 = "lists this title but has no playable copy" (seen lasting
  days), 401/403/404 have their own messages; network loss and "too many connections" statuses re-queue with an
  exponential backoff instead of failing, and the app retries them as soon as `NWPathMonitor` reports the network back.
- `StreamResolver.movie/episode` return the completed file when there is one, so a downloaded title plays from disk
  everywhere (works offline, uses no provider connection). A completed download whose file was moved or deleted is
  marked failed ("File was moved or deleted") at launch or when played, and comes back if the file reappears.
- Single-connection accounts: while the player streams from a source with `maxConnections == 1`, `AppModel` calls
  `suspend()` (the running transfer stops and is marked auto-paused) and `unsuspend()` afterwards; `PlayerSlot.beforeLoad`
  waits for the connection to be released (up to 2 s) before opening the stream.

### Updates (Sparkle 2)

- Same setup as Soonbar: `UpdaterService` wraps `SPUStandardUpdaterController` and turns on only when the app's
  `Info.plist` contains `SUPublicEDKey`, which `scripts/release.sh` adds to release builds; local builds never update
  themselves. Installed copies read `releases/latest/download/appcast.xml` (a release asset, so publishing needs no
  commit) about once a day.
- Integrity: the zip's EdDSA signature (key in the maintainer's login keychain) is checked against the installed app's
  public key before anything is installed. The app is only ad-hoc signed, so Sparkle can't match Apple code signatures
  between versions; it accepts an update when the EdDSA signature is valid. Verified end to end with a scratch build:
  1.1.0 → 1.1.1 installs and relaunches; a tampered zip and an intact app signed with another key are both rejected.
- `scripts/build-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks` (rpath `@executable_path/../Frameworks`)
  and signs the bundle with `--deep`. `TUNER_UPDATE_FEED` points a test build at a local appcast; scratch runs with
  `TUNER_DATA_DIR` and no test feed never check.

### On-device AI features (Settings → AI, all off by default)

Each is a pref (`aiGuideMatching`, `aiRecommendations`, `aiNaturalLanguageSearch`); off means exactly the
previous code path and no extra work. Logic lives in TunerCore with tests; nothing leaves the device.

- **Smart guide matching** (`GuideMatcher`): runs only when `GuideService.smartMatching` is on. Ingest also keeps
  programmes for each feed's best fuzzy pick among channels with no guide or only an automatic one;
  `resolveEPGKeys` gives channels still without a key (and without an override) the matcher's pick and records it
  in `epgAutoMatch` (migration `v6-epgAutoMatch`). Off: the table is emptied and resolution is exactly override →
  Stalker → tvg-id → normalised name. Names are cleaned (quality/VIP/backup tags, country/language prefixes,
  number words, Arabic transliterated); numbers, timeshift, region and country must agree and every word needs a
  partner; score = 0.6 × edit-distance similarity + 0.4 × word agreement, ≥ 0.8 to match; Arabic vs Latin only by
  consonant skeleton; near-ties between different names are refused.
- **Up Next** (Home, always on; not an AI setting): `AppDatabase.smartContinueWatching` (one read,
  `SmartContinueWatching.rank`) gives each show's next cached episode when its newest record is a finished
  episode (`EpisodeNavigation`, no network; none after the finale or if already watched). Continue Watching itself
  is plain recency (`continueWatching`). A "Smart Continue Watching" setting that also re-ordered and hid
  resume points existed in 1.3–1.8 and was removed.
- **Recommendations** (`RecommendationIndex`, `Recommender`): a content-based index with no model. Each movie/show
  is a sparse TF-IDF vector over weighted tokens (genre ×2, director ×2, cast ×1.5, language ×1.5, category ×1.2,
  title ×1.2, category words ×0.6, plot ×0.5), with genres/languages canonicalised from English and Arabic and
  text normalised once for both (harakat/tatweel removed, alef/yaa/taa marbuta unified, ال stripped, EN+AR stop
  words). Queries: cosine similarity through an inverted index × year proximity × rating prior, then MMR with a
  per-category cap; the title itself and other copies of it are excluded. The `Recommender` actor builds the index
  lazily off the main actor (≈0.9 s for 50k titles in release, ≈22 MB) and rebuilds in the background when a cheap
  library fingerprint changes; hidden categories and the adult filter apply per query (≈3 ms). No new tables.
- **Natural-language search** (`QueryUnderstanding`): a rule-based EN/AR parser (Arabic spelling folded, articles
  and prefixes removed, a lexicon plus year grammar) into `SearchFilter`s and leftover title text; connecting words
  are dropped only next to understood words, and `AppDatabase.understandSearch` keeps the query plain when it
  names a library title ("Family Guy"). Channels and programmes are searched as typed. The optional Foundation
  Models step (`NaturalSearchModel`, app target, `DynamicGenerationSchema` so no macro plugin is needed) runs only
  on Return for English 3+-word queries with leftover words and no results, with a 6 s timeout, and
  `QueryUnderstanding.refine` validates its answer. FoundationModels is weak-linked (`-weak_framework`) so the
  Mac app still launches on macOS 15.

### Top 10 rows

`TopTenService` (TunerCore actor, tested) gets public popularity charts and matches them with the library. Sources in
order (`TopTenRegion.chain`): Netflix's Top 10 for the device's country (`all-weeks-countries.tsv`, ~32 MB, grouped
by country, newest week first), Netflix worldwide (`all-weeks-global.tsv`), TMDB weekly trending (only with the
user's key) and Cinemeta `catalog/{movie,series}/top`. Netflix's server ignores Range and If-Modified-Since, so
`NetflixTop10.LatestWeekParser` reads the file line by line and stops once the wanted week is complete (global ≈3 KB,
Egypt ≈7 MB); the country file is skipped on cellular and Low Data Mode. Charts are cached in `popularityChart`
(migration `v6-topTen`) and reused offline; Netflix is checked again only once the next week can be out, the others
every 6 h, a failure waits an hour. `TopTenMatcher` matches by IMDb/TMDB id first (provider or cached metadata), else
by equal cleaned names (TitleMatcher clean-up, Arabic and English parts compared separately) with agreeing years; a
yearless chart title matching library items from different years is skipped. Duplicates come from the most-watched
playlist; hidden (and, when hidden, adult) categories are left out. A row uses the first source with ≥ 3 matches and
shows up to 10, each with its chart rank (`ChartEntry.rank`: Netflix's `weekly_rank` in a country list, a show at its best season; otherwise its position in the list), gaps kept. Off: the service is never called.

### Artwork loading

`RemoteImage` loads through `ArtworkLoader` rather than `AsyncImage` + `URLCache`: decoded images stay in an
`NSCache` keyed by URL and a pixel-size bucket (the largest copy per URL is drawn in the first frame, so there's no
placeholder flash when scrolling back); bytes go to `ImageDiskCache` (TunerCore, 600 MB, least recently used out,
file names are SHA-256 of the URL) whatever the server's caching headers say; decoding uses ImageIO's thumbnail
path off the main thread, sized to the view. One request per URL is shared by every view asking for it.

### Sync between devices (iCloud Drive folder)

**Why not CloudKit:** the iPhone app is signed with a free Personal Team and the Mac app is ad-hoc/Developer ID signed
from SwiftPM, so neither can have the iCloud/CloudKit entitlement. Sync goes through a plain folder in iCloud Drive
instead: on the Mac `~/Library/Mobile Documents/com~apple~CloudDocs/Tuner Sync/` (created when iCloud Drive is on,
or any folder chosen with the open panel); on iPhone/iPad a folder picked once in the Files picker, kept as a
security-scoped bookmark (`UserDefaults`), resolved and opened for each pass (a stale bookmark is refreshed, or the
user is asked again). Off by default (Settings → Sync).

- **One file per device**, `<deviceId>.json` (device id: a UUID made once, in `UserDefaults`). A device writes only
  its own file and reads the others, so there are no write conflicts. Reads and writes are coordinated
  (`NSFileCoordinator`), writes atomic; iCloud placeholders (`.<name>.json.icloud`) and evicted files get
  `startDownloadingUbiquitousItem` and are read on a later pass. Corrupt, partial and other-schema files are skipped
  with a status message. The file is only rewritten when its records change.
- **Change detection by snapshot diff** (`CloudSyncMerge.diff`), so no write site had to change: the `syncLedger`
  table (migration `v7-syncLedger`) keeps, per key, what this device last published, its time (ms) and a hash of the
  local data it came from. Each pass builds the current state (`AppDatabase.snapshot`); a changed hash means a local
  change (time = now, or the record's own newer time: watch progress `updatedAt`, history `watchedAt`, favourite
  `addedAt`); a key that vanished becomes a deletion (pruned after 60 days; playlist deletions are kept). On a
  device's very first sync its values get a provisional time older than everything, so the other devices' settings
  win over a fresh install's defaults.
- **Merge** (`CloudSyncMerge.decide`): per key, the newest record across all files wins (ties: the larger device
  id). Applied values are written to the tables in the same transaction and recorded in the ledger with the remote
  time, the remote value published verbatim and the hash of what the local tables now hold, so they aren't
  re-exported as local changes (no ping-pong when two devices hold cosmetically different forms of a value).
- **Ids across devices:** local ids are `"<sourceId>_<suffix>"` with a random source id per device (channels,
  categories, movies, series, episodes — Xtream, Stalker and M3U alike). Files use `"<fingerprint>|<suffix>"`
  (`CloudSyncSourceMap`); the fingerprint (`SourceFingerprint`) hashes the kind, the normalised URL (lowercased scheme
  and host, no default port, user info or trailing slash, password/token-like query parameters removed, the rest
  sorted), the lowercased username and the Stalker MAC — never the password. Records of a playlist this device
  doesn't have are left alone (not applied, not in the ledger) and apply once the playlist appears.
- **What syncs** (`CloudSyncKind`): `progress` (position, duration, completed, title, subtitle, poster, kind, show),
  `vodFavorite`, `channelPref` (favourite + order, hidden, alias, guide override — an XMLTV id, synced as is),
  `categoryPref` (hidden, alias, order), `history`, `group` and `groupMember`, whitelisted preferences
  (`CloudSyncPreferences.keys`: recent searches, pinned categories — ids translated, and a change keeps pins of
  playlists this device doesn't have — category names, adult filter, episode pictures, autoplay/Up Next, resume,
  metadata on/language, accent, the AI toggles and Top 10), and `source`: a playlist's settings with the URL's
  secrets removed and no password (URLs with secrets are left out of the backup/guide lists). Never synced: downloads,
  recordings, reminders, guide data, metadata caches, the library itself, and device-specific preferences (engine,
  buffers, paths, user agents, TMDB key, shortcuts, volume, last channel).
- **Playlists:** one that arrives without its secret (Xtream, or an M3U link whose token was removed) is created off
  with `source.needsPassword` (migration `v7-sourceNeedsPassword`): provider sync skips it and Settings → Playlists
  shows "Needs password"; saving the editor with the password turns it on. Others (Stalker, plain M3U) are created
  on and refreshed. A playlist removed on one device stays on the others (its deletion is published but never
  applied); its records simply stop syncing from that device. Editing a playlist's server or username changes its
  fingerprint, so the other devices get it as a new playlist.
- **When** (`CloudSyncController`, app target): after the library loads, when the app becomes active, every 2 minutes
  while it is, 3 s after user-state or preference changes (60 s after watch-progress saves, which happen every few
  seconds during playback), when leaving the app if a pass is pending, and on Sync Now. Passes run in the
  `CloudSyncEngine` actor (one at a time, never while a source editor is open); applied rows bump the usual revisions
  through the table observers. `TUNER_SYNC_DIR` (or `-TunerSyncDir` in iOS debug builds) uses a plain folder and turns
  sync on, for testing; a scratch library (`TUNER_DATA_DIR`) defaults to `<data dir>/Sync`, never iCloud Drive.
  Logging: `Logger(subsystem: "app.tuner.macos", category: "Sync")`, counts only.

File format (schema 1; `updatedAt` in ms since 1970; `deleted` records have no value):

```json
{"appVersion":"1.6.0","deviceId":"6F1C…","deviceName":"Mac","exportedAt":"2026-10-29T10:00:00Z","platform":"macOS","schema":1,
 "records":[
  {"key":"channelPref/3fa9c2e1d07b5a6c4e21|101","updatedAt":1793260800000,"value":{"alias":null,"epgIdOverride":"news.example","favoriteOrder":1,"isFavorite":true,"isHidden":false}},
  {"key":"progress/3fa9c2e1d07b5a6c4e21|vod_7","updatedAt":1793260812345,"value":{"completed":false,"duration":6000,"kind":"movie","position":1200,"posterURL":null,"seriesId":null,"subtitle":"2024","title":"A Movie"}},
  {"key":"groupMember/0D2B…/3fa9c2e1d07b5a6c4e21|101","updatedAt":1793260800000,"value":{"sortIndex":0}},
  {"key":"pref/accent","updatedAt":1793260800000,"value":"purple"},
  {"key":"source/3fa9c2e1d07b5a6c4e21","updatedAt":1793260800000,"value":{"kind":"xtream","name":"My Provider","needsSecret":true,"url":"http://provider.example:8080","username":"me","…":"…"}},
  {"deleted":true,"key":"vodFavorite/3fa9c2e1d07b5a6c4e21|vod_9","updatedAt":1793260900000}
 ]}
```

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
    Database/      AppDatabase (migrations), Records, +Library (sync writes), +Queries, +User (prefs, progress…),
                   +Downloads
    Downloads/     DownloadService (actor: queue, resume, suspend), FileTransfer (one URLSession per transfer),
                   DownloadFiles (naming, free space)
    Skip/          Skip Intro: SkipSegments (chapter titles, sanity checks, merge), SkipTracker, SkipLearner,
                   SkipSegmentService (actor: TheIntroDB/IntroDB lookups + cache)
    Audio/         AudioEnhancementProcessor (tap DSP), Biquad, Dynamics (compressor, leveller), MPVAudioFilterChain,
                   SleepTimer
    CloudSync/     iCloud Drive folder sync: SourceFingerprint, CloudSyncMerge (diff + LWW), CloudSyncFolder (file I/O),
                   CloudSyncEngine (actor); AppDatabase+CloudSync (snapshot, apply, ledger)
    Services/      SyncService (actor), GuideService (actor: ingest + key resolution), StreamResolver (actor),
                   RecordingService (actor, ffmpeg), M3UExporter
  Tuner/       (SwiftUI app, Swift 5 mode)
    App/           TunerApp, AppModel (@Observable root + actions + background loops), Preferences, Navigation,
                   RootView (sidebar shell + window-level player), KeyboardShortcuts + menu commands,
                   Updates/ (UpdaterService: Sparkle wrapper + "Check for Updates…")
    Player/        PlaybackEngine, AVEngine (primary), MPVEngine + MPVVideoLayer (fallback), PlayerSlot (routing,
                   watchdog, failover, progress), PlayerManager (the slot, presentation), SlotVideoView, PlaybackItem
    Views/         Live/ (guide), VOD/ (Home, Movies, TV Shows, details, Search), Player/ (presentation,
                   chrome, video overlay, mini), Settings/ (settings, source editor, welcome), Recordings/, Downloads/,
                   Common/
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
- `download` — downloads for offline viewing, one row per movie/episode id (state, bytes, file path, error); no
  foreign keys, so a download outlives a resync that drops the title or a removed playlist.
- `epgFeed`, `epgChannel(key = feedId|xmltvId)`, `program(epgKey, start, end, …)`. `channel.epgKey` is resolved
  after each guide ingest: override → Stalker native → tvg-id → normalised name; preferring keys with programmes,
  then the channel's own source feeds, then global feeds, then other sources' feeds.
- `watchProgress`, `vodFavorite`, `history` (recent channels), `customGroup(+Member)`, `reminder`, `recording`.
- `syncLedger` — iCloud sync: per key, what this device last published and the hash of the local data behind it.
- `skipSegmentCache` (online intro/credits times per movie/episode id), `skipLearnedSpan` (spans skipped by hand, per
  show and episode) — Skip Intro.
- Failover candidates are computed on demand (same EPG key, tvg-id or normalised name) instead of curated groups.

## UX — Apple TV app style (user requirement: "fully native, experience like the Apple TV app")

- Native `NavigationSplitView` sidebar: Search · Home · Live TV · Movies · TV Shows · Recordings, then
  "Channels" (Favorites, Recently Watched, custom groups).
- Home: rotating hero artwork + shelves (Continue Watching, On Now, Recently Added, Top Rated, Favorites).
- Movies / TV Shows: category chips + poster grid; detail pages with backdrop hero, capsule Play/Resume, seasons
  and episode cards with progress; autoplay of the next episode.
- Live TV: 16:9 live preview + now/next header, category chips + source picker, guide grid (sticky ruler and
  channel column, now-line, catchup/reminder/recording markers), channel context menu.
- Player: one persistent video view that moves between **full window** (sidebar collapses, TV-app glass
  controls that auto-hide), the guide **preview**, and a **mini player** while browsing — never recreated.
  (Multiview was removed on 2026-10-06 at the owner's request.)
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

## iPhone and iPad (one codebase)

The iPhone/iPad app (iOS/iPadOS 26+, personal installs, never the App Store) compiles the Mac app's sources. History
and the original research: `ios-handover.md`, `ios-port-research.md`.

| Concern | Decision | Why |
|---|---|---|
| Project | `iOS/project.yml` (XcodeGen) → `TunerIOS.xcodeproj` (git-ignored) with target sources `../Sources/Tuner` + `iOS/Sources`; `TunerCore` from the local package | No file moves: the Mac app keeps building with SwiftPM and the Command Line Tools; the `.pbxproj` is generated, not reviewed |
| Shared code | Mac-only code behind `#if os(macOS)` (imports, whole declarations, a few modifiers). iOS versions of AppKit-only types keep the **same names and initialisers** (`AVPlayerHostView`, `MPVRenderer`/`MPVVideoLayer`/`MPVVideoView`, `SlotVideoView`, `TunerApp`…) | Shared files compile unchanged on both; the Mac binary is the same code as before |
| AppKit names | `iOS/Sources/Support/AppKitCompat.swift` maps simple AppKit API onto UIKit (`NSImage`, `NSWorkspace.open` → Files/Safari, `NSPasteboard`, `NSOpenPanel` → document picker, `NSViewRepresentable` → `UIViewRepresentable`); no-ops for Mac-only concepts (window full screen, cursor) | Keeps `#if` out of view bodies |
| Layout | `EnvironmentValues.tunerCompact` (always on an iPhone, and on narrow iPad windows; never on the Mac) switches shared views to iPhone layouts: channel list instead of the guide grid, stacked headers, and the TV app–style player chrome (`PlayerPhoneChrome`: no panel, one even dim, transport on the video, timeline and pills below) | One flag; the Mac always takes the regular path. Not the size class alone: a Pro Max in landscape reports a regular width, which used to swap in the Mac panel and turn the touch gestures off |
| Engines | Same routing as the Mac (AVFoundation first, mpv fallback, HEVC-in-TS detection). mpv is MPVKit 1.0.0 (GPL build, linked statically), rendering through the same libmpv OpenGL render API into a `CAEAGLLayer` (OpenGL ES 3) | `MPVEngine` is shared; only the renderer differs. GPL is fine for builds that are never distributed |
| mpv decoding | Device: `hwdec=videotoolbox-copy`; simulator: `hwdec=no` | Zero-copy VideoToolbox frames rendered a solid colour into the GLES context; the simulator's VideoToolbox corrupts HEVC |
| Background | GLES draws stop in the background (iOS kills apps that use the GPU there) and mpv's video track is switched off, so audio continues; AVPlayer's layer is detached unless Picture in Picture is showing it | Background audio for both engines |
| Not on iOS | Recording (needs the ffmpeg process), the ffmpeg AirPlay bridge, Sparkle, the shortcut editor, choosing a downloads folder, PiP for mpv content | Platform limits; the owner declined mpv PiP |
| Downloads | Documents/Downloads (visible in Files), excluded from iCloud backup | Re-downloadable, large |

## Improvements over ynotv

Per-channel `#EXTVLCOPT` user-agent/referrer, URL-encoded credentials, commas in titles, M3U VOD grouping,
user state that survives resyncs, failed syncs retried and errors cleared on success, native-first engine routing
(`.m3u8` for AVFoundation, `.ts`/MKV to mpv), no wasted second connection on definitive HTTP errors,
empty-guide detection with guidance.

## Testing

- `scripts/test.sh` — 42 Swift Testing tests for `TunerCore` (parsers, gzip, catchup URLs, Xtream/Stalker helpers,
  normalisation, title parsing, database semantics, guide key resolution).
- `scripts/testkit/` + `docs/testing.md` — local mock providers (M3U + XMLTV, Xtream panel, live TS/HLS, dead and
  flaky channels, multi-track VOD) used for end-to-end UI testing of the built app.
- Verified on a real Xtream account: 11,950 channels / 41,080 movies / 15,030 series synced in 25 s.
