# Appendix A — Port map: Swift → Kotlin

Part of the Google TV design (`../2026-11-15-google-tv-design.md`). This is the file-by-file list of what to port,
where it goes, and what to watch for. **The Swift source is the source of truth for exact algorithms**: this
appendix tells you which file to read, what it's responsible for, and the traps. Read the Swift file in full before
porting it; don't port from this summary alone.

Line counts are from commit `7b464e2` (Tuner 1.10.1) and give a sense of size.

## How to port a file

1. Read the Swift file and its test file(s) completely.
2. Create the Kotlin file at the destination below, same type names, first line:
   `// Port of Sources/TunerCore/<path>.swift @ <short sha>`.
3. Port the tests first (JUnit 5 + kotlin.test in `core`; JUnit 4 + Robolectric in Android modules), then the
   code, until they pass.
4. If the area is a vector area (Appendix E), generate golden outputs from Swift and make Kotlin match them too.
5. Record the port in `docs/android-parity.md` (area, Swift file, sha, deliberate differences).

## Kotlin translation traps (read before porting anything)

These are the differences that silently change results. Each has bitten Swift→Kotlin ports before.

| Swift | Kotlin trap | Do this |
|---|---|---|
| `String` compares and iterates by extended grapheme cluster; `.unicodeScalars` by code point | Kotlin `String`/`Char` are UTF-16 code units; surrogate pairs split; `"é"` (precomposed) ≠ `"é"` (combining) in both, but Swift `==` treats canonically equivalent strings as equal | Iterate code points (`codePoints()` / `Character.toChars`) wherever Swift uses `unicodeScalars`; where Swift compares strings with `==` on user text, normalise both to NFC first |
| `for ch in s` (`Character`) with `ch.isLetter` / `ch.isNumber` | `Char.isLetter()` works on one UTF-16 unit and excludes marks | For a grapheme loop, iterate code points and test the first code point's category; Swift `isLetter` = Unicode `Alphabetic`; `isNumber` = numeric types (Nd, Nl, No) |
| `CharacterSet.alphanumerics` | Not `isLetterOrDigit`: Apple's set is Unicode general categories **L\*, M\*, N\*** (marks included: Arabic harakat count as alphanumeric) | Test `Character.getType(cp)` against the L/M/N categories |
| `lowercased()` / `uppercased()` (locale-independent) | `toLowerCase()` uses the default locale (Turkish dotless i) | Always `lowercase()` / `uppercase()` (Kotlin's are `Locale.ROOT`), never `toLowerCase()` |
| `folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)` | No direct equivalent | NFD → remove `\p{Mn}` → lowercase → map full-width forms to ASCII (U+FF01–FF5E → U+0021–007E, U+3000 → space). **Don't** use NFKC wholesale: it also rewrites superscripts (ᴴᴰ → HD) and ligatures, which Apple's folding doesn't. Verify against Swift-generated vectors (Appendix E) |
| `NSRegularExpression` (ICU) | `java.util.regex` differs in `\w`, `\b`, `\d` (ASCII-only by default) and in case-insensitive matching of non-ASCII | Compile with `Pattern.UNICODE_CHARACTER_CLASS` (and `UNICODE_CASE` with `CASE_INSENSITIVE`) when the Swift pattern relies on Unicode classes; keep ASCII classes (`[A-Za-z]`) literal |
| `Int32` arithmetic with `&*`, `&+` (wrapping) and plain `+` (traps on overflow) | Kotlin `Int` always wraps silently | Use `Int` for wrapping math (DJB2); where Swift would trap, it doesn't matter in practice, but don't add `Long` "for safety" to wrapping hashes: it changes the result |
| `abs(Int32.min)` handled explicitly in `StableID.hash` | `Math.abs(Int.MIN_VALUE)` is negative | Port the special case exactly (`Int.MIN_VALUE` → `2147483648L`) |
| `String(n, radix: 36)` lowercase | `toString(36)` is lowercase too | Same; then take the first 8 characters |
| `Dictionary` iteration order is random per process | `LinkedHashMap`/JSON objects keep insertion order | Don't rely on order where Swift sorts afterwards; where Swift doesn't sort (rare), the result was order-independent: keep it that way |
| `Double(string)` / `Int(string)` | `toDoubleOrNull()` accepts `"1e3"`, `"NaN"`, `"Infinity"`, which `Double(_:)` also does; `Int("+5")` works in Swift and `"+5".toIntOrNull()` works too; `Int(" 5")` fails in both | Port `LenientJSON` helpers exactly; they define what panels' sloppy values mean |
| `DateFormatter` with `en_US_POSIX` + UTC | `SimpleDateFormat` is not thread-safe; default zone is the device's | `java.time` (`DateTimeFormatter.ofPattern(..., Locale.ROOT).withZone(ZoneOffset.UTC)`); Android minSdk 28 has `java.time` natively |
| `Date` (seconds since 2001, `Double`) | — | Store instants as epoch **milliseconds** `Long` in Room, except `program.start/end` which are epoch **seconds** `Long` as in Swift |
| `URLComponents` percent-encoding | `java.net.URI` is stricter; `HttpUrl` (OkHttp) normalises | Build Xtream paths with the same encoders as Swift (`urlPathEncoded`, `urlQueryEncoded` in `Sources/TunerCore/Networking`); test with usernames/passwords containing `@ : / ? # % + space` and Arabic letters |
| Swift `sort` (unstable in principle) | `sortedWith` is stable | Fine; where ties matter, Swift code already adds tie-breakers. Port them |
| `async`/`actor` | Coroutines; no actor isolation | An `actor` becomes a class whose mutable state is guarded by a `Mutex` (kotlinx.coroutines.sync) or confined to a single-threaded dispatcher (`Dispatchers.IO.limitedParallelism(1)`). Never call blocking I/O on `Dispatchers.Main` |

## `core` module (Kotlin/JVM, no Android)

Package root `app.tuner.core`. Folder = Swift folder.

### Parsing

| Swift (lines) | Kotlin | Responsibility and notes |
|---|---|---|
| `Parsing/StableID.swift` (71) | `parsing/StableID.kt` | DJB2 hash over **UTF-8 bytes** (wrapping Int32, absolute value with the `Int.MIN` case, base-36, max 8 chars); `sanitize` (anything outside `[A-Za-z0-9._-]` → `_`, per code point); `slug` (lowercase, keep L/M/N code points, collapse other runs to one `-`, trim trailing `-`, empty → `category-<hash>`). `M3UChannelIDAllocator`: tvg-id → `<src>_<sanitized tvg>`, else `<src>_url_<hash(url)>`, collisions get `_<hash(url)>` then `_2`, `_3`… **Vector area** |
| `Parsing/M3UParser.swift` (391) | `parsing/M3UParser.kt` | Byte-level parser over a stream. Must keep: UTF-8 BOM skip; `\r\n`/`\n`/`\r` line ends; commas inside quoted attributes and titles; attributes with spaces around `=`; unclosed quote reads to the next comma; `key= key2="v"` doesn't swallow the next key; `#EXTVLCOPT:http-user-agent=` / `http-referrer=`; `#EXTGRP:`; any URL scheme kept; comma-separated `url-tvg`; Xtream-style `/movie/` and `/series/` URLs routed into movies / series (series grouped from "Show S01 E02" names); `/live/{user}/{pass}/{id}.ts` → `providerStreamId`. Ids: live categories `<src>_<slug(group)>`, movie categories `<src>_vod_<slug>`, movies `<src>_vod_<hash(url)>` (+`_n` on collision), series categories `<src>_series_<slug>`, series `<src>_series_<slug(show)>`, episodes `<src>_ep_<hash(url)>`. The file also holds the VOD title heuristics (year in brackets anywhere; trailing year only after an explicit separator; "Blade Runner 2049" is not a year). Process 100k-entry files streaming; never hold the file as one `String`. **Vector area** |
| `Parsing/XMLTVParser.swift` (416) | `parsing/XMLTVParser.kt` | Byte scanner (Swift uses mmap). Use a streaming pull parser over a buffered `InputStream` (don't build a DOM; `XmlPullParser` from the JVM-available `kxml2`/`xmlpull` or a hand-written byte scanner like Swift's: choose by the 1M-programme benchmark). Port its time parsing (`YYYYMMDDhhmmss ±zzzz`, missing offset, short forms) exactly. Wanted-channel filtering happens in `GuideService` (below). **Vector area** |
| `Parsing/Gzip.swift` (52) | `parsing/Gzip.kt` | Detect gzip by magic bytes (not the URL); handle **multi-member** gzip (concatenated members). `java.util.zip.GZIPInputStream` only continues to the next member when the underlying stream's `available()` is > 0, so on network streams it can stop after the first member and silently truncate the guide. Either download to a file first (recommended for XMLTV anyway: lets the parse retry without refetching) or loop over members explicitly with `Inflater`. Test with `Fixtures/multi.xml.gz` read through a stream whose `available()` returns 0 |
| `Parsing/ChannelNameNormalizer.swift` (48) | `parsing/ChannelNameNormalizer.kt` | Folding (see traps), country-prefix regex, bracket removal, `&`→` and `, `+`→` plus `, tokenise on letter/number, drop noise tokens (exact set in the Swift file), never normalise to empty. **Vector area** |
| `Parsing/CatchupURLBuilder.swift` (117) | `parsing/CatchupURLBuilder.kt` | `append`, `shift`, `flussonic`, `default` templates; `{utc}`, `{lutc}`, `{duration}`, `{duration:60}`, `{offset:60}`, `{Y}{m}{d}{H}{M}{S}` style placeholders (read the Swift `substitute` for the full list); UTC, zero-padded. **Vector area** |
| `Parsing/IMDbDatasetScanner.swift` | — | Not in v1 (IMDb episode ratings deferred) |

### Networking

| Swift | Kotlin | Notes |
|---|---|---|
| `Networking/HTTPClient.swift` (175) | `net/HttpClient.kt` (OkHttp) | Default User-Agent **`VLC/3.0.20 LibVLC/3.0.20`** (exact string); timeout 30 s default (`max(timeout,120)` for large downloads: read the file); per-request UA and Referer; no retry on 4xx; the retry/backoff rules in the file; `HTTPError` cases with the same user-facing messages. One shared `OkHttpClient` (connection pool) with per-call timeouts via `newBuilder()`. Never log URLs |
| `Networking/LenientJSON.swift` (80) | `net/LenientJson.kt` | `JSONObject` wrapper: `string`/`int`/`double`/`bool`/`date`/`object` accessors that accept numbers as strings, strings as numbers, `"1"`/`"true"` booleans, empty arrays where objects are expected, unix timestamps as strings. Build on `kotlinx.serialization.json.JsonElement`. **Port the accessor semantics exactly**: they decide what panels' values mean |
| `Networking/ImageDiskCache.swift` | — | Replaced by Coil's disk cache |
| URL encoders (`urlPathEncoded`, `urlQueryEncoded`; find their definitions with `grep -rn "urlPathEncoded" Sources/TunerCore`) | `net/UrlEncoding.kt` | Same allowed character sets as Swift. **Vector area** (encode a list of tricky usernames/passwords) |

### Providers

| Swift | Kotlin | Notes |
|---|---|---|
| `Providers/XtreamClient.swift` (319) | `providers/XtreamClient.kt` | `player_api.php?username=&password=[&action=]`. Auth: requires `user_info.auth == 1`, status `active` (else error with the status), server time offset from `server_info.time_now` (as UTC) − `timestamp_now`, rounded to the nearest 15 minutes; EPG candidates (`<base>/xmltv.php?...` then the `server_info` host/port/protocol variant). Actions: `get_live_categories`, `get_live_streams`, `get_vod_categories`, `get_vod_streams`, `get_vod_info` (`vod_id`), `get_series_categories`, `get_series`, `get_series_info` (`series_id`). Ids: live `<src>_<stream_id>`, live categories `<src>_<category_id>`, movies `<src>_vod_<id>`, series `<src>_series_<id>`, episodes `<src>_ep_<episode id>`. `get_series_info.episodes` is either `{"1":[…]}` or `[[…],[…]]`. Playback URLs: `/live/u/p/<id>.<ts|m3u8>`, `/movie/u/p/<id>.<ext or mp4>`, `/series/u/p/<id>.<ext or mp4>`, `/timeshift/u/p/<minutes>/<YYYY-MM-DD:HH-mm in server-local time>/<id>.ts`. `parseCredentials` from pasted `get.php`/`player_api.php` links. **Xtream channel `streamURL` is stored empty**: URLs (with credentials) are built at play time only |
| `Providers/StalkerClient.swift` (485) | `providers/StalkerClient.kt` | MAG emulation: User-Agent `Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3` (exact), 60 s timeout; endpoint discovery over `…/portal.php`, `…/server/load.php`, `/stalker_portal/server/load.php`, `/c/portal.php` (order in the file); `handshake` → token, `get_profile`; `Authorization: Bearer <token>` and the MAC cookie; calls `?type=&action=&JsHttpRequest=1-xml`, payload under `js`; token refresh on auth failure; VOD paging (14 per page; categories synced, items loaded when a category opens, cached 30 min); `create_link` at play time (never store resolved links: they're tokenised); strip `ffmpeg `/`ffrt ` prefixes; rewrite localhost/relative links to the portal origin; archive via `tv_archive` `create_link`. `StalkerLocator` (opaque `stalker:` locator stored in `streamURL`): port its encoding exactly (it's in the same file) |

### Models

| Swift | Kotlin | Notes |
|---|---|---|
| `Models/Source.swift` | `models/Source.kt` | Fields and defaults as in Swift (`autoLoadEPG=true`, `includeLive/VOD=true`, `refreshHours=null` = global, `0` = manual). `baseURL` strips trailing `/`. `supportsVOD = kind != m3u` |
| `Models/Channel.swift` | `models/Channel.kt` | `CategoryKind` (`live`/`movie`/`series`), `Category`, `CatchupType` with `init(m3uValue:)` mapping (`append`; `shift`/`siptv`/`timeshift`; `flussonic`/`flussonic-hls`/`flussonic-ts`/`fs`; `xc` → xtream; else `default`), `Channel` (+ joined user state), `displayName` (alias if non-blank), `hasCatchup` (`catchupType != null && (catchupDays ?: 1) > 0`) |
| `Models/Program.swift`, `Models/VOD.swift`, `Models/Library.swift` | `models/…` | `Program`, `EPGFeed`, `EPGChannel`, `Movie`, `Series`, `Episode`, `VODDetails`, `WatchProgress` (incl. `isComplete(position,duration)`: read the rule in `VOD.swift`), `MediaKind`, library aggregates |
| `Models/CategoryGrouping.swift` (301) | `models/CategoryGrouping.kt` | Menus (Featured, Languages & Countries, Platforms, Genres, By Year, Sports, Kids, Quality, More) from English and Arabic category names; `CategoryNameStyle` (`automatic`/`arabic`/`original`). **Vector area** (category name → menu, display name per style) |
| `Models/EpisodeNavigation.swift` (60) | `models/EpisodeNavigation.kt` | Previous/next episode across seasons; Up Next countdown seconds (`duration >= countdown*2`, `0 < remaining <= countdown`, rounded up); `EndOfMediaStall` (`window = 15 s`, `patience = 3 s`, needs `duration > 30 s`). **Vector area** |
| `Models/SmartContinueWatching.swift` (187) | `models/SmartContinueWatching.kt` | Continue Watching / Up Next ranking. Constants: nearly finished ≥ 0.75 watched or < 15 min left, only within 30 days; recent-show window 7 days; abandoned = < 0.2 watched and untouched 21 days; resume threshold 10 s; reset threshold 5 s. Per show the newest record decides (resume / next episode / none). 27 Swift tests: port them all. **Vector area** |
| `Models/PullCharge.swift` | — | iPhone pull-to-refresh; not on TV |

### Services

| Swift | Kotlin | Notes |
|---|---|---|
| `Services/SyncService.swift` (365) | `data/…/SyncService.kt` (needs the DB, so it lives in `data`; keep its pure helpers in `core`) | One sync per source at a time; live and VOD attempted independently (one failing doesn't hide the other); guide problems reported but don't fail the playlist; each part stamped on its own success (`lastSyncedAt`, `lastVODSyncedAt`); backup URLs tried in order, a working backup is **promoted to primary**; M3U series come with their episodes inline; Xtream movies and series fetched independently, categories+items concurrently, the two big downloads one after the other; Stalker: categories only, items lazily; scheduled refresh (sources older than their interval; global defaults live 6 h, VOD 24 h); lazy series episodes (`get_series_info` on open, falls back to stored); Stalker category items cached 30 min; `test(source)` validates without writing |
| `Services/GuideService.swift` (454) | `data/…/GuideService.kt` | Feeds per source in priority order (manual or discovered primary, then extras); feed ids `<src>#0`, `<src>#<n>`, Stalker `<src>#stalker`; primary slot tries each candidate URL, first working one saved as `discoveredEPGURL`; a failed feed keeps its previous data; feeds no longer used are removed; global feeds (no source); empty `<tv></tv>` is valid; only programmes for wanted channels (lowercased tvg-ids, normalised names incl. alternative display names) are kept; programmes older than the catchup window dropped (constant in the file); **key resolution order: override → Stalker native → tvg-id → normalised name; prefer keys with programmes, then the channel's own source feeds, then global feeds, then other sources' feeds.** Smart matching (`GuideMatcher`) is not in v1: implement the "off" path only (empty `epgAutoMatch`) |
| `Services/StreamResolver.swift` (201) | `data/…/StreamResolver.kt` | UA precedence: channel UA → source UA → (Stalker: MAG UA) → default UA. Live: Xtream builds `/live/` URL (format `ts` default on Android, see design), Stalker resolves its locator, M3U uses the stored URL (an Xtream-panel M3U `.ts` can be switched to `.m3u8`). Catchup: start = programme start − padding, end = min(programme end + padding, now) (if ≤ start, programme end), minutes rounded up; Stalker `create_link` archive; Xtream timeshift with the cached server offset (per source, from `authenticate()`); M3U without `catchup-source` but with an Xtream-panel URL uses that panel's timeshift; otherwise `CatchupURLBuilder`. `makeURL` trims, percent-encodes with the fragment-allowed set as a fallback, `/`-prefixed paths are files. Downloads (`downloadedFile`) aren't in v1. **Vector area** for the pure URL building |
| `Services/GuideMatcher.swift`, `M3UExporter.swift`, `RecordingService.swift` | — | Not in v1 |

### Skip Intro, metadata

| Swift | Kotlin | Notes |
|---|---|---|
| `Skip/SkipSegments.swift` (302) | `skip/SkipSegments.kt` | Chapter-title detection, sanity checks, merge of online segments against the playing file. **Vector area** |
| `Skip/SkipSegmentService.swift` (207) | `data/…/SkipSegmentService.kt` | TheIntroDB `GET https://api.theintrodb.org/v4/media?imdb_id=…[&season=&episode=]` (TMDB id when no IMDb id) and IntroDB `GET https://api.introdb.app/segments?imdb_id=…&season=&episode=` or `&is_movie=true`, asked together, no keys, one short attempt; cache found 30 days, not found 7 days, network failure caches nothing; send only ids and numbers; log database names and status codes only |
| `Skip/SkipLearner.swift` | — | Later (not v1); keep the `skipLearnedSpan` table out of v1 |
| `Player/SkipController.swift` (app target, 315) | `player/SkipController.kt` | When to show Skip Intro / Skip Credits and what "automatic" does (`SkipMode`: `button` default, `automatic`, `off`). Read it fully |
| `Metadata/MetadataService.swift`, `CinemetaClient.swift` (`https://v3-cinemeta.strem.io`), `TMDBClient.swift` (`https://api.themoviedb.org/3`, images `https://image.tmdb.org/t/p/`), `TVmazeClient.swift` (`https://api.tvmaze.com`, episode pictures), `TitleMatcher.swift`, `MediaMetadata.swift`, `MetadataHTTP.swift` | `metadata/…` (pure parts in `core`, cache in `data`) | Title logos, backdrops, cast, ratings, trailers (stored, not played in v1), episode pictures. Cache in `mediaMetadata` (incl. not-found), 30-day refresh. `TitleMatcher` decides which online title a playlist entry is: port with its tests (part of `MetadataTests.swift`, 51 tests: port the matcher/client ones) |
| `Metadata/IMDbRatingsService.swift`, `OnlineGuideCatalog.swift` | — | Not in v1 |

### CloudSync

| Swift | Kotlin | Notes |
|---|---|---|
| `CloudSync/SourceFingerprint.swift` (109) | `sync/SourceFingerprint.kt` | Only this file in v1 (sync-ready ids). Kind + normalised URL (lowercased scheme/host, no default port, no user info, no trailing slash, password/token-like query params removed, rest sorted) + lowercased username + Stalker MAC; never the password. **Vector area** |

## App-target logic to port (from `Sources/Tuner`, no Swift tests)

Write new Kotlin tests for these.

| Swift | Kotlin | Notes |
|---|---|---|
| `Player/PlayerSlot.swift` (1,170) | `player/PlayerSlot.kt` | See Appendix C for the full behaviour |
| `Player/EngineMemory.swift` | `player/EngineMemory.kt` | 30 days; per channel/movie/episode id; an episode also marks its show; stored in DataStore/SharedPreferences |
| `Player/PlaybackEngine.swift`, `PlaybackItem.swift` | `player/PlaybackEngine.kt`, `PlaybackItem.kt` | Interfaces and item ids (`ch:<id>`, `cu:<id>:<start epoch s>`, `mv:<id>`, `ep:<id>`); recordings dropped |
| `Player/SkipController.swift` | `player/SkipController.kt` | Above |
| `App/Preferences.swift` | `app/Preferences.kt` | Keys and defaults: Appendix D |
| `App/AppModel.swift` (1,244) | split into ViewModels + `AppRepository` | Actions, background loops (refresh shortly after launch, then every 10 minutes for stale sources; once-per-launch guide failure suppression), library revision observation |
| `Views/**` | `app/ui/**` | Behaviour reference only. The TV UI is designed in Appendix D, not translated |

## Swift tests to port in v1

| Swift test file | `@Test`s | Port |
|---|---|---|
| `ParserTests.swift` | 35 | All (M3U, XMLTV, gzip, normaliser, catchup, Stalker parsing) |
| `SmartContinueWatchingTests.swift` | 27 | All |
| `SkipSegmentsTests.swift` | 28 | All except `SkipLearner` cases |
| `EpisodeNavigationTests.swift` | 13 | All |
| `CategoryGroupingTests.swift` | 13 | All |
| `DatabaseTests.swift` | 18 | Those covering tables in v1 (Appendix B); as Room/Robolectric tests |
| `MetadataTests.swift` | 51 | Cinemeta/TMDB/TVmaze clients, `TitleMatcher`, metadata cache; skip IMDb-ratings parts |
| `CloudSyncTests.swift` | 17 | Only `SourceFingerprint` cases |
| `StubHTTPServer.swift` | — | Replace with OkHttp `MockWebServer` |
| `LibraryPerfBenchmark.swift` | 2 | Port as a benchmark (not run in normal test runs) |
| Others (Audio, Downloads, GuideMatcher, IMDb, Recommendations, QueryUnderstanding, TopTen, CloudSyncRoundTrip, ImageDiskCache, PullCharge) | — | Not in v1 |
