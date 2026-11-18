# Android parity

How the Google TV app (`android/`) follows the Apple apps. Base: the commit in `android/PARITY_BASE`. Outstanding
work: `scripts/android-backlog.sh`. Mechanism: `docs/superpowers/specs/google-tv/E-parity-tooling.md`.
What's usable and what was deferred: `docs/android-roadmap.md`.

## Ported areas

| Area | Swift file(s) | Kotlin file(s) | Ported from | Notes |
|---|---|---|---|---|
| Stable ids | `Parsing/StableID.swift` | `core/…/parsing/StableID.kt` | 666f598 | vectors |
| Channel names | `Parsing/ChannelNameNormalizer.swift` | `parsing/ChannelNameNormalizer.kt` | 666f598 | vectors; folding rule in appendix A |
| Catchup URLs | `Parsing/CatchupURLBuilder.swift` | `parsing/CatchupURLBuilder.kt` | 666f598 | vectors |
| M3U | `Parsing/M3UParser.swift` (+ `TitleParser`) | `parsing/M3UParser.kt`, `TitleParser.kt` | 666f598 | 11 tests + vectors |
| XMLTV, gzip | `Parsing/XMLTVParser.swift`, `Gzip.swift` | `parsing/XMLTVParser.kt`, `Gzip.kt` | 666f598 | 9 tests + vectors |
| Guide parse step | `Services/GuideService.swift` (`parse`) | `services/GuideParse.kt` | 666f598 | no smart matching (v1) |
| JSON, HTTP | `Networking/LenientJSON.swift`, `HTTPClient.swift` | `net/LenientJson.kt`, `HttpClient.kt`, `UrlEncoding.kt` | 666f598 | vectors; OkHttp |
| Xtream | `Providers/XtreamClient.swift` | `providers/XtreamClient.kt`, `XtreamURLs.kt` | 666f598 | mock-server tests + vectors |
| Stalker | `Providers/StalkerClient.swift` | `providers/StalkerClient.kt` | 666f598 | mock-server tests |
| Models | `Models/Source, Channel, Program, VOD` | `models/*.kt` | 666f598 | |
| Category grouping | `Models/CategoryGrouping.swift` | `models/CategoryGrouping.kt` | 666f598 | vectors |
| Episode navigation | `Models/EpisodeNavigation.swift` | `models/EpisodeNavigation.kt` | 666f598 | 13 tests |
| Continue Watching | `Models/SmartContinueWatching.swift` | `models/SmartContinueWatching.kt` | 666f598 | 21 tests; DB suite owed (roadmap) |
| Skip segments | `Skip/SkipSegments.swift` | `skip/SkipSegments.kt` | 666f598 | vectors; SkipLearner not in v1 |
| Fingerprint | `CloudSync/SourceFingerprint.swift` | `sync/SourceFingerprint.kt` | 666f598 | vectors |
| Metadata | `Metadata/MediaMetadata, MetadataHTTP, TitleMatcher, CinemetaClient, TMDBClient, TVmazeClient, MetadataService` | `metadata/*.kt` | 666f598 | 37 tests + vectors; cache behind `MetadataCache` (Room `Library`) |
| Skip lookups | `Skip/SkipSegmentService.swift` | `skip/SkipSegmentService.kt` | 666f598 | 7 tests; cache behind `SkipSegmentCache`; no learned intros (v1) |
| VOD items, Home hero | `Views/VOD/VODCards.swift` (`VODItem`, `VODFormat`), `HomeView.swift` (`heroPicks`) | `models/VODItem.kt` | c361462 | 5 tests; app-target code on Apple, in core here so it's tested |

## Deliberate differences

- **Xtream live format.** Android requests `.ts` first and falls back to `.m3u8`; Apple requests HLS for AVFoundation
  and TS for mpv. ExoPlayer plays raw TS well and starts faster.
- **Typed searches are remembered.** Apple keeps a search only once a result from it is opened; with a remote,
  typing is slow and a search is often just looked at, so TV also keeps one on going down to the results or after a
  pause with results (`RecentSearches.rememberTyped`).
- **Home screen channel.** Android TV launchers show an app's own row (`HomeChannel`); Apple has no equivalent (Top
  Shelf would be the tvOS one).
- **Quick reopen default.** A closed movie or episode stays ready for 2 minutes by default on TV (Apple: 10). TV boxes
  have little RAM. The setting offers the same choices.
- **Home's first focus.** TV Home opens on the hero's Play button, as the Apple TV app does, rather than on the first
  Continue Watching card (appendix D): focusing a row scrolls it to the top, which hid the hero on every launch.
  Continue Watching is the first row under the hero, one press down.
