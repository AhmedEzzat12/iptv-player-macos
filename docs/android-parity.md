# Android parity

How the Google TV app (`android/`) follows the Apple apps. Base: the commit in `android/PARITY_BASE`. Outstanding
work: `scripts/android-backlog.sh`. Mechanism: `docs/superpowers/specs/google-tv/E-parity-tooling.md`.

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
| Continue Watching | `Models/SmartContinueWatching.swift` | `models/SmartContinueWatching.kt` | 666f598 | 21 tests; DB suite in phase 3 |
| Skip segments | `Skip/SkipSegments.swift` | `skip/SkipSegments.kt` | 666f598 | vectors; SkipLearner not in v1 |
| Fingerprint | `CloudSync/SourceFingerprint.swift` | `sync/SourceFingerprint.kt` | 666f598 | vectors |
| Metadata | `Metadata/MediaMetadata, MetadataHTTP, TitleMatcher, CinemetaClient, TMDBClient, TVmazeClient, MetadataService` | `metadata/*.kt` | 666f598 | 37 tests + vectors; cache behind `MetadataCache` (Room in phase 3) |
| Skip lookups | `Skip/SkipSegmentService.swift` | `skip/SkipSegmentService.kt` | 666f598 | 7 tests; cache behind `SkipSegmentCache`; no learned intros (v1) |

## Deliberate differences

- **Xtream live format.** Android requests `.ts` first and falls back to `.m3u8`; Apple requests HLS for AVFoundation
  and TS for mpv. ExoPlayer plays raw TS well and starts faster.
- **Quick reopen default.** A closed movie or episode stays ready for 2 minutes by default on TV (Apple: 10). TV boxes
  have little RAM. The setting offers the same choices.
