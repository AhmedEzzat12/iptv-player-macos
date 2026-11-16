# Appendix B — Data: schema, ids, ingest, queries

Part of the Google TV design (`../2026-11-15-google-tv-design.md`). Swift reference:
`Sources/TunerCore/Database/` (`AppDatabase.swift` holds the migrations; `+Library`, `+Queries`, `+User`,
`+Metadata`, `+SkipSegments` the reads and writes).

## Database setup

- One SQLite file `tuner.sqlite` in the app's private files dir (`context.filesDir`), opened with Room.
- WAL set explicitly (`setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)`: Room's automatic mode picks TRUNCATE on
  low-RAM devices, which includes many TV boxes), `PRAGMA synchronous = NORMAL`, `temp_store = MEMORY`, `cache_size = -32000`
  (Swift sets these in `prepareDatabase`; set them in a `RoomDatabase.Callback.onOpen`). Foreign keys on.
- Room schema export on (`room.schemaLocation` = `android/data/schemas`), committed, so migrations are reviewable.
- Version 1 of the Android schema = the tables below. Later changes are new Room migrations; never edit old ones
  (same rule as `AppDatabase.migrator`).
- Instants: epoch **milliseconds** (`Long`) for every `datetime` column in Swift, except `program.start/end`, which
  are epoch **seconds** (`Long`), as in Swift. Booleans as `INTEGER` 0/1. JSON arrays (`extraEPGURLs`,
  `backupURLs`) as `TEXT` with kotlinx.serialization (a `TypeConverter`).

## Tables in v1

Column names and meaning match Swift exactly (same names, so a later sync port maps 1:1). Types: T = TEXT,
I = INTEGER, R = REAL, B = boolean (INTEGER), J = JSON TEXT, ms = epoch-ms INTEGER, s = epoch-s INTEGER.
"NN" = not null. Default values in brackets.

### `source`

`id` T PK · `name` T NN · `kind` T NN (`m3u`|`xtream`|`stalker`) · `url` T NN · `username` T · `password` T
(**ciphertext**, see Secrets) · `mac` T · `epgURL` T · `autoLoadEPG` B NN [1] · `extraEPGURLs` J NN [`[]`] ·
`epgTimeshiftHours` R NN [0] · `userAgent` T · `backupURLs` J NN [`[]`] · `enabled` B NN [1] · `includeLive` B NN
[1] · `includeVOD` B NN [1] · `refreshHours` I (null = global, 0 = manual) · `sortIndex` I NN [0] · `createdAt` ms
NN · `lastSyncedAt` ms · `lastVODSyncedAt` ms · `lastError` T · `expiresAt` ms · `activeConnections` I ·
`maxConnections` I · `discoveredEPGURL` T · `channelCount` I NN [0] · `movieCount` I NN [0] · `seriesCount` I NN [0]
· `needsPassword` B NN [0].

`discoveredEPGURL` for Xtream contains the account's credentials (it's `xmltv.php?username=…&password=…`). It's
stored as in Swift (the app sandbox protects it), but never logged and never shown in full in the UI (show host only).

### `category`

`id` T PK · `sourceId` T NN → `source.id` ON DELETE CASCADE · `kind` T NN (`live`|`movie`|`series`) · `name` T NN ·
`providerOrder` I NN. Index (`sourceId`, `kind`).

### `categoryPref`

`categoryId` T PK · `isHidden` B NN [0] · `alias` T · `sortIndex` I. No foreign key (survives resyncs).

### `channel`

`id` T PK · `sourceId` T NN → source CASCADE · `categoryId` T · `name` T NN · `normalizedName` T NN · `number` I ·
`providerOrder` I NN · `logoURL` T · `tvgId` T · `streamURL` T NN (Xtream: empty; Stalker: `stalker:` locator; M3U:
the URL) · `providerStreamId` T · `catchupType` T · `catchupSource` T · `catchupDays` I · `userAgent` T · `referrer`
T · `isAdult` B NN [0] · `epgKey` T. Indexes: (`sourceId`,`providerOrder`), (`categoryId`,`providerOrder`),
(`epgKey`), (`normalizedName`), (`tvgId`).

### `channelPref`

`channelId` T PK · `isFavorite` B NN [0] · `favoriteOrder` I · `isHidden` B NN [0] · `alias` T · `epgIdOverride` T.

### `movie`

`id` T PK · `sourceId` T NN → source CASCADE · `categoryId` T · `name` T NN · `year` T · `posterURL` T ·
`backdropURL` T · `providerId` T NN · `containerExtension` T · `streamURL` T NN · `rating` R · `plot` T · `genre` T ·
`cast` T · `director` T · `releaseDate` T · `durationSeconds` I · `addedAt` R (epoch seconds, as the provider gives
it) · `providerOrder` I NN · `trailer` T · `tmdbId` T. Indexes: (`categoryId`), (`sourceId`), (`addedAt`), and the
three sort indexes from `v9-vodSortIndexes` with **identical expressions** to the queries that use them:
`(addedAt IS NULL, addedAt DESC, providerOrder)`, `(name COLLATE NOCASE)`,
`(rating IS NULL, rating DESC, name COLLATE NOCASE)`. Room can't declare expression indexes: create them in the
migration/`onCreate` callback with raw SQL.

### `series`

As Swift: `id`, `sourceId` (CASCADE), `categoryId`, `name`, `year`, `coverURL`, `backdropURL`, `providerId`,
`rating`, `plot`, `genre`, `cast`, `director`, `releaseDate`, `addedAt` R, `lastModified` R, `providerOrder`,
`trailer`, `streamURL` T NN [`""`]. Same indexes as `movie` (category, source, the three sort indexes).

### `episode`

`id` T PK · `seriesId` T NN · `sourceId` T NN → source CASCADE · `season` I NN · `number` I NN · `title` T NN ·
`plot` T · `imageURL` T · `durationSeconds` I · `providerId` T NN · `containerExtension` T · `streamURL` T NN ·
`airDate` T. Index (`seriesId`, `season`, `number`).

### `epgFeed`, `epgChannel`, `program`

- `epgFeed`: `id` T PK · `url` T NN · `sourceId` T → source CASCADE (null = global feed) · `priority` I NN ·
  `lastFetchedAt` ms · `lastError` T · `channelCount` I NN [0] · `programCount` I NN [0].
- `epgChannel`: `key` T PK (`<feedId>|<xmltvId>`) · `feedId` T NN → epgFeed CASCADE · `xmltvId` T NN ·
  `displayName` T NN · `normalizedName` T NN · `iconURL` T · `programCount` I NN [0]. Indexes (`feedId`),
  (`normalizedName`).
- `program`: `id` I PK autoincrement · `feedId` T NN → epgFeed CASCADE · `epgKey` T NN · `start` s NN · `end` s NN ·
  `title` T NN · `subtitle` T · `summary` T · `category` T · `iconURL` T · `episode` T. Indexes (`epgKey`,`start`),
  (`end`), (`feedId`).

### User state

- `watchProgress`: `mediaId` T PK · `kind` T NN (`movie`|`episode`) · `sourceId` T NN · `seriesId` T · `title` T NN ·
  `subtitle` T · `posterURL` T · `position` R NN · `duration` R NN · `completed` B NN [0] · `updatedAt` ms NN.
  Indexes (`updatedAt`), (`seriesId`).
- `vodFavorite`: `mediaId` T PK · `kind` T NN · `addedAt` ms NN.
- `history`: `channelId` T PK · `watchedAt` ms NN.
- `customGroup` (`id`, `name`, `sortIndex`) and `customGroupMember` (`groupId` → customGroup CASCADE, `channelId`,
  `sortIndex`, PK (`groupId`,`channelId`)): created in v1 (the Favorites drawer item lists groups), UI to create
  and edit groups is v1 too (channel long-press menu → Add to Group).

### Caches

- `mediaMetadata`: `mediaId` T PK · `kind` T NN · `json` T · `notFound` B NN [0] · `fetchedAt` ms NN. `json` is the
  encoded metadata model (Kotlin's own serialisation; it doesn't need to match Swift's bytes).
- `skipSegmentCache`: `mediaId` T PK · `json` T NN (encoded `List<SkipSegment>`, empty = not found) · `fetchedAt` ms NN.

### Not in v1

`reminder`, `recording`, `imdbEpisodeRating`, `imdbRatingScan`, `download`, `epgAutoMatch`, `popularityChart`,
`syncLedger`, `skipLearnedSpan`. Don't create them yet; they arrive with their features as new migrations.

## Secrets

- `source.password` holds ciphertext: AES-256-GCM with a key in the Android Keystore (`KeyGenParameterSpec`,
  alias `tuner-source-secrets`, no user authentication required, `setIsStrongBoxBacked(false)`; TV boxes rarely
  have StrongBox). Stored as `base64(iv) + ":" + base64(ciphertext)`.
- Decrypt only when building a request (Xtream URL, Stalker login, M3U URL with a token). Never hold decrypted
  passwords in long-lived objects, logs, crash reports or `toString()` (override `toString` on `Source`).
- A row whose ciphertext can't be decrypted (restored from backup onto another device: the Keystore key didn't
  travel) gets `needsPassword = 1`, `enabled` stays as it was, and the source is skipped by sync until the user
  re-enters the password (the QR page opens pre-filled, Appendix D).
- M3U URLs can carry credentials too (`get.php?username=&password=`). Treat an M3U `url` containing a
  `password`/`token`-like query parameter with care: `url` stays plain text (ids and `SourceFingerprint` need it),
  but it's never logged and the UI shows only its host.

## Backup

- `android:fullBackupContent` / `dataExtractionRules` (API 31+): include the database and DataStore; **exclude**
  nothing else of value (caches are re-fetchable: exclude `cacheDir` implicitly).
- Passwords don't restore (Keystore key is device-bound), so restored sources show "Password needed" (above).
- M3U URLs with embedded credentials restore in plain text: accepted (same as Swift's iCloud backup of the Mac
  library), documented in the README's privacy notes.

## Ids (must match Swift exactly)

| Thing | Format | Source |
|---|---|---|
| Source | random UUID string (uppercase, like Swift `UUID().uuidString`) | `Source.init` |
| Xtream live category | `<src>_<category_id>` | `XtreamClient` |
| Xtream channel | `<src>_<stream_id>` | `XtreamClient` |
| Xtream movie category / movie | `<src>_vod_<category_id>` / `<src>_vod_<stream_id>` | `XtreamClient` |
| Xtream series category / series | `<src>_series_<category_id>` / `<src>_series_<series_id>` | `XtreamClient` |
| Xtream episode | `<src>_ep_<episode id>` | `XtreamClient.seriesInfo` |
| M3U channel | `<src>_<sanitize(tvg-id)>`, else `<src>_url_<hash(url)>`, collisions suffixed | `M3UChannelIDAllocator` |
| M3U live category | `<src>_<slug(group)>` | `M3UParser` |
| M3U movie category / movie | `<src>_vod_<slug(group)>` / `<src>_vod_<hash(url)>[_n]` | `M3UParser` |
| M3U series category / series / episode | `<src>_series_<slug(group)>` / `<src>_series_<slug(show)>` / `<src>_ep_<hash(url)>` | `M3UParser` |
| Stalker live category / channel | `<src>_<genre id>` / `<src>_<channel id>` | `StalkerClient` |
| Stalker VOD category | `<src>_<prefix>_<id>` (prefix per kind, read the file) | `StalkerClient` |
| Stalker movie / series | `<src>_vod_<id>` / `<src>_series_<id>` | `StalkerClient` |
| Stalker episode | `<src>_ep_<eid>` or `<src>_ep_<seriesProviderId>_<season>_<n>` | `StalkerClient` (two cases) |
| EPG feed | `<src>#0`, `<src>#<n>`, `<src>#stalker`; global feeds: read `GuideService` | `GuideService` |
| EPG channel key | `<feedId>|<xmltvId>` | `GuideService` |

## Ingest (sync writes)

Port `AppDatabase+Library.swift` behaviour:

- **Replace per source in one transaction**: delete the source's categories/channels (or movies/series) and insert
  the new rows; user state lives in `*Pref`/`watchProgress`/`vodFavorite`/`history` and is untouched.
- Carry resolved `epgKey` over from the old channel rows (same id) so the guide doesn't blank until the next key
  resolution.
- `replaceEpisodes`: skip the write when the provider sent what's stored (opening a show must not count as a library
  change); batch many shows in one transaction (M3U).
- The episode re-key step (keeps watch progress on the right episode when a provider renumbers ids): read
  `AppDatabase+Library.swift` around line 162 and port it.
- `updateMovieDetails` / `updateSeriesDetails`: `UPDATE … SET col = COALESCE(?, col)` only for rows where a value
  differs.
- `updateSyncStatus` updates status fields without clobbering configuration edited meanwhile (read-modify-write of
  status columns only).
- **Performance**: inserts through one prepared statement per table (`SupportSQLiteStatement`, bind + `executeInsert`
  in a loop) inside one transaction; Room `@Insert` with a `List` is acceptable only if the benchmark passes.
  Programmes: insert in chunks of 5,000 within the feed's transaction.
- `pruneProgrammes(endedBefore:)` after each guide refresh (cutoff constant in `GuideService.swift`).

## Reads used by the UI (port from `AppDatabase+Queries.swift`, `+User.swift`)

`channels(scope, search, sort, includeHidden, limit)` (scopes: all, source, category, favourites, recent, group —
read `ChannelScope`), `channel(id)`, `channels(epgKeys)`, `alternateChannels(for:)` (same EPG key, tvg-id or
normalised name: failover candidates), `categories(kind, sourceId, includeHidden)` (with item counts),
`category(id)`, `guideCoverage(sourceId)`, `programs(epgKeys, from, to)` (overlapping `[from,to)`, grouped by key,
sorted, **each programme's end clamped to the next one's start**), `searchPrograms(query, from, hours=72,
limit=200)`, `epgChannels(matching)`, `movies(...)`/`series(...)` with `VODSort` (`added`, `name`, `year`,
`rating`, `provider`; ORDER BY expressions identical to the indexes), `episodes(seriesId)`, progress reads,
`smartContinueWatching(limit=20, now)` (resume points + next cached episode, ranked by `SmartContinueWatching`; one
read, no network), `continueWatching` (`completed = 0 AND position > 10`), favourites, groups.

Writes: favourite/hidden/alias/EPG override per channel, category hidden/alias, `recordWatched(channelId)`,
`saveProgress` (**ignores zero-length media** so a failed load can't wipe progress; `completed` from
`WatchProgress.isComplete`), `markWatched` (one or many in one transaction), `deleteProgress`, VOD favourites,
groups CRUD.

Expose reads as suspend functions for one-shot loads and as `Flow`s (Room `@Query` returning `Flow`, or
`InvalidationTracker` on the tables) for screens that must refresh when sync writes, matching Swift's
`libraryRevision` (`channel`, `category`, `movie`, `series`, `episode`, `source`), `guideRevision` (`program`,
`epgChannel`, `epgFeed`, `channel.epgKey`) and `userRevision` (`*Pref`, `watchProgress`, `vodFavorite`, `history`,
groups). Debounce invalidations (a few hundred ms; read how `AppModel` bumps its revisions and match it).

## Settings storage

Jetpack DataStore (Preferences), keys and defaults in Appendix D. Same key names as `Preferences.swift`, so a later
sync port can reuse `CloudSyncPreferences.keys`.
