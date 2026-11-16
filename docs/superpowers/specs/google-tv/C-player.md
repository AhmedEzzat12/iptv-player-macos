# Appendix C — Player

Part of the Google TV design (`../2026-11-15-google-tv-design.md`). Swift reference: `Sources/Tuner/Player/`
(`PlayerSlot.swift` is the heart; `PlaybackEngine.swift`, `PlaybackItem.swift`, `EngineMemory.swift`,
`SkipController.swift`, `MPVEngine.swift`) and `Sources/TunerCore/Models/EpisodeNavigation.swift`. Read
`PlayerSlot.swift` in full before writing `player/`.

## Module layout (`android/player`)

```
player/
  PlaybackEngine.kt      interface + EngineSnapshot + EngineEvent + MediaTrack + VideoAspect
  PlaybackItem.kt        Channel | Catchup(channel, program) | Movie | Episode(episode, series)
  ExoPlayerEngine.kt     Media3 ExoPlayer implementation
  MpvEngine.kt           libmpv implementation (JNI wrapper module or AAR)
  PlayerSlot.kt          routing, fallback, watchdog, failover, progress, park, seek goal, end-of-media
  EngineMemory.kt        "this item needs mpv" memory, 30 days
  SkipController.kt      Skip Intro / Credits
  PlayerSession.kt       Media3 MediaSession wiring (remote keys, Assistant)
  ui/                    PlayerScreen (Compose), chrome, overlays, Up Next card, track menus
```

## Engine interface

Same surface as Swift's `PlaybackEngine` minus Apple-only parts (AirPlay, PiP, audio enhancements in v1). All calls
on the main thread; events delivered on the main thread.

```kotlin
interface PlaybackEngine {
    val name: String                        // "ExoPlayer" or "mpv" (shown in the stats overlay)
    val surface: android.view.View          // created once, reused for the engine's lifetime
    var onEvent: ((EngineEvent) -> Unit)?
    fun load(stream: PlayableStream, startAt: Double?)   // seconds; seek once loaded (resume)
    fun stop()
    fun setPaused(paused: Boolean)
    fun seekTo(seconds: Double)
    fun seekBy(delta: Double)
    fun setVolume(volume: Double)           // 0..100, same perceptual curve for both engines (see AVEngine.setVolume)
    fun setMuted(muted: Boolean)
    fun setAspect(aspect: VideoAspect)      // fit, fill, stretch, 16:9, 4:3
    fun snapshot(): EngineSnapshot          // polled every 0.5 s
    fun audioTracks(): List<MediaTrack>
    fun subtitleTracks(): List<MediaTrack>
    fun selectAudioTrack(id: Int)
    fun selectSubtitleTrack(id: Int?)       // null = off
    suspend fun chapters(): List<ChapterMark>
    fun shutdown()
}

sealed interface EngineEvent {
    data object Loaded : EngineEvent
    data object Ended : EngineEvent
    data class Failed(val message: String) : EngineEvent
    data class HttpError(val status: Int) : EngineEvent
    data object VideoUnsupported : EngineEvent   // audio plays, video can't be decoded; sent before Loaded
}
```

`EngineSnapshot` fields as Swift: `position`, `duration`, `isPaused`, `isBuffering`, `isIdle`, `reachedEnd`,
`bufferedEnd`, `bufferedSeconds`, `videoSize`, `videoCodec`, `audioCodec`, `fps`, `videoBitrate`, `audioBitrate`,
`hardwareDecoder`, `droppedFrames`, `isSeekable`, `networkSpeed`.

`PlayableStream` (`url`, `userAgent`, `referrer`, `kind` live/catchup/vod, `headers`) comes from `StreamResolver`
(Appendix A). Both engines must send `User-Agent` and `Referer` on **every** request including HLS segments and
redirects.

## ExoPlayerEngine

- `ExoPlayer.Builder` with `DefaultRenderersFactory` + `EXTENSION_RENDERER_MODE_ON` (so the FFmpeg audio renderer is
  used when the platform lacks a decoder), `DefaultLoadControl` sized from the buffer preference (default 150 MB
  target, matching `bufferMegabytes`), `OkHttpDataSource.Factory` on the shared OkHttp client with per-stream
  headers.
- Media source by URL: `.m3u8` → `HlsMediaSource`; otherwise `ProgressiveMediaSource` (TS, MP4, MKV). Set
  `setAllowChunklessPreparation(true)` for HLS. For live TS set `DefaultExtractorsFactory().setTsExtractorFlags(
  FLAG_ALLOW_NON_IDR_KEYFRAMES or FLAG_DETECT_ACCESS_UNITS)` (IPTV TS often starts mid-GOP).
- Map `PlaybackException` codes to events: `ERROR_CODE_IO_BAD_HTTP_STATUS` → `HttpError(status)` then `Failed`;
  `ERROR_CODE_DECODER_INIT_FAILED`/`DECODING_FORMAT_UNSUPPORTED`/`DECODING_FORMAT_EXCEEDS_CAPABILITIES` → `Failed`
  (routing falls back to mpv); behind-live-window → re-prepare at the live edge silently.
- **Video unsupported**: at `STATE_READY`, if `currentTracks` has an audio group selected but the video group is
  unsupported (`isSupported == false` for all its tracks) or absent while the container announced video, send
  `VideoUnsupported` within 1.5 s (same as Swift's hold), before `Loaded`.
- Tracks: `Tracks` groups → `MediaTrack` (id = index across groups of that type), selection through
  `TrackSelectionParameters` overrides. Subtitles rendered with Media3 `SubtitleView` styled like the Apple app
  (white, soft shadow, 4% of screen height).
- Audio passthrough: `AudioCapabilities` from the system; when the TV/receiver supports AC-3/E-AC-3/DTS, pass
  through (ExoPlayer does this by default via `DefaultAudioSink`); otherwise decode (platform or FFmpeg extension).
- `chapters()`: ExoPlayer exposes MP4/MKV chapters only partially; return what the metadata gives (empty is fine:
  Skip Intro then relies on the online databases).

## MpvEngine

- libmpv, **LGPL build** (`-Dgpl=false`; FFmpeg configured without `--enable-gpl`/`--enable-nonfree`), ABIs
  armeabi-v7a, arm64-v8a, x86_64. Built by a script in `android/mpv/` (adapted from mpv-android's
  `buildscripts`) or taken from an LGPL AAR whose build is reproducible; either way the source versions are listed
  in Acknowledgements.
- JNI wrapper: a small C file exposing create/initialize/command/set_option/get_property/observe/event loop/destroy
  (mpv-android's `MPVLib` is a good model; MIT licensed).
- Rendering: `SurfaceView` → `vo=gpu` with `gpu-context=android` and `hwdec=mediacodec-copy` (safe default; try
  `mediacodec` + `vo=mediacodec_embed` on the TCL and keep it if it works: lower CPU). Options as Swift's
  `MPVEngine` where they apply: `cache=yes`, `demuxer-max-bytes` from the buffer preference, `user-agent`,
  `referrer`, `http-header-fields`, `network-timeout`, `load-scripts=no`, `osc=no`, `ytdl=no`, `config=no`, and
  every built-in script switch off (same list as the Mac App Store build in `docs/design.md` → "No Lua in the store
  app": `load-stats-overlay`, `load-console`, `load-osd-console`, `load-auto-profiles`, `load-select`,
  `load-positioning`, `load-commands`, `load-context-menu`, `scripts=`).
- Events: `MPV_EVENT_FILE_LOADED` → `Loaded`; `end-file` with `reason=eof` → `Ended`, `error` → `Failed`; HTTP
  status from the log (`[ffmpeg] http: HTTP error 403`) → `HttpError` (port the Swift log parsing).
- Surface lifecycle: on `surfaceDestroyed` detach (`vo` keeps state); when the app goes to the background, stop
  playback (TV apps don't play in the background; see "Lifecycle").

## Routing (PlayerSlot)

Port Swift's routing with these Android rules:

1. Engine preference (`engine`: `automatic` default, `mpv`, `exoplayer`). Forced engines skip fallback.
2. **Automatic:** ExoPlayer first for everything, unless `EngineMemory` says the item (or, for an episode, its show)
   needs mpv: then mpv first.
3. Xtream live is requested as `.ts` (Android decision). If ExoPlayer fails on `.ts`, retry ExoPlayer once with
   `.m3u8` before falling back to mpv with `.ts`. (Swift does HLS-for-AVFoundation / TS-for-mpv; the rule differs on
   purpose: record it in `docs/android-parity.md`.)
4. **Fallback once** to the other engine on: `Failed` (not after a 4xx `HttpError`: another decoder can't fix 401/403/
   404 and a second request wastes a connection on single-connection accounts), `VideoUnsupported`, or the **15 s
   load timeout**.
5. One automatic retry for transient 5xx in the same engine (connection hand-off races), as Swift.
6. Remember in `EngineMemory` only when mpv then actually plays (a stop, a slow network or a stream neither engine
   opens must not send the title to mpv for a month); a load timeout alone isn't remembered.
7. Close the current stream **before** resolving/opening the next one (single-connection accounts refuse a second
   stream).
8. "One failure per load attempt": engines report `HttpError` then `Failed` for the same problem; act once.
9. The 503 message rule: a 503 from the panel itself means the title has no playable copy; say so and point at the
   provider (port the Swift message builder, `PlayerSlot.swift` "Explains a failed stream").

## Live watchdog and failover

Port exactly (`PlayerSlot.watchdog`, `streamDied`):

- Poll every 0.5 s. Progress = position advanced > 0.25 s or buffered end advanced > 0.25 s. Progress resets
  `retryCount`, clears the status message and resets the failover-tried set to the current channel.
- Grace after load: 6 s (10 s while retrying). Then the stream is dead if `reachedEnd`, or idle and stalled > 4 s, or
  stalled > `stallTimeoutSeconds` (default 12).
- Dead: if `autoFailover` (default on), try the first untried of [original channel] + `alternateChannels` (same EPG
  key, tvg-id or normalised name), status "Switching to <name>…". Otherwise/afterwards reconnect with backoff
  `min(retryCount, 5)` seconds, status "Reconnecting (n/max)…", up to `maxRetries` (default 10), then fail with
  "This channel isn't responding. <reason>."

## Finite media (movies, episodes, catchup)

- **Progress saving** (movies/episodes only, `progressKey` = media id), as `PlayerSlot.saveProgress`: forced on stop,
  on switching to another item chosen by the user, and at the end (position = duration, completed); otherwise at most
  every 9 s from the poll (every 20th 0.5 s tick). Skipped when duration is unknown or 0, or position ≤ 5 s (unless
  completing). Record fields: movie → title = name, subtitle = year, poster = backdrop ?: poster; episode → title =
  show name, subtitle = `S<season>, E<number> · <episode title>`, poster = episode image ?: show backdrop ?: cover,
  `seriesId` = show id. `completed` = `WatchProgress.isComplete`: position/duration ≥ 0.9 or ≤ 5 s left.
- **Resume** (`resumePlayback`, default on): start at the saved position if > 10 s and not completed; the detail page
  offers "Resume" and "Play from Beginning".
- **End of media**: either `Ended`, polled `reachedEnd`, or `EndOfMediaStall.hasEnded(position, duration,
  stalledFor)` (stuck within 15 s of the end for 3 s, not paused) finishes the item. Act once.
- **Up Next** (`autoplayNextEpisode` default on, `upNextCountdown` default 10 s, 0 = no card, start at once): the card
  appears when `EpisodeNavigation`'s countdown says so; buttons "Play Now" (focused) and "Cancel"; at zero the next
  episode starts. Next across seasons. Not after the last episode.
- **Seek goal**: ±10 s and scrubber seeks move the displayed time at once; quick repeated seeks add up from the
  previous target, not the stale engine position (`seekGoal`).
- **Quick reopen** (`keepWarmMinutes`, default 10 on Apple; **default 2 on TV**: TV boxes have little RAM): closing a
  movie/episode keeps its engine paused; reopening the same item continues from the buffer (a different `startAt`
  seeks). Not for live TV, local files or catchup. Anything else that plays, a failure/end while parked, or the
  timeout closes it. Swift parks on single-connection accounts only while no download is waiting
  (`AppModel`); Android has no downloads in v1, so it always parks (the kept stream is closed before anything else
  opens, so it never holds a second connection).

## Skip Intro / Credits

Port `SkipController` + `SkipSegments` + `SkipSegmentService`. `skipSegments` preference: `button` (default; a
"Skip Intro" / "Skip Credits" pill bottom-right, focus moves to it automatically when it appears, OK skips, it
disappears at the segment end), `automatic` (skips with a brief "Skipped Intro" toast), `off`. Credits skip on the
last episode = end of item (no Up Next).

## Lifecycle

- Leaving the app (Home button, input switch, screensaver) stops playback and releases engines (save progress
  first). Returning shows the last screen; the player is not auto-resumed, except live TV if
  `resumeLastChannelOnLaunch` and the user was watching live when leaving.
- Keep the screen on while loading, playing or buffering (`FLAG_KEEP_SCREEN_ON` on the player window); clear it on
  pause after 0 s (TV screensaver may start).
- Low memory (`onTrimMemory` ≥ `TRIM_MEMORY_RUNNING_LOW`): drop the parked engine, shrink the image cache.

## Remote control in the player

| Key (`KeyEvent`) | Live TV | Movie / episode / catchup |
|---|---|---|
| `DPAD_CENTER`/`ENTER` | toggle chrome; with chrome shown, activate the focused control | same |
| `DPAD_LEFT`/`RIGHT` | chrome hidden: nothing; shown: move focus | chrome hidden: seek −10/+10 s (repeat while held: 10 s steps, after 2 s of holding 30 s steps); shown: move focus (on the scrubber: seek) |
| `DPAD_UP` | show chrome with focus on the top row (info, audio, subtitles) | same |
| `DPAD_DOWN` | channel strip of the current category (scrolls horizontally, OK tunes) | episodes strip (shows) |
| `CHANNEL_UP`/`DOWN`, `PAGE_UP`/`DOWN` | previous/next channel in the current list (banner with name/number/now if `showChannelBannerOnZap`) | next/previous episode |
| `MEDIA_PLAY_PAUSE`, `MEDIA_PLAY`, `MEDIA_PAUSE` | pause/resume (catchup only; live: stop/restart at live edge) | pause/resume |
| `MEDIA_FAST_FORWARD`/`REWIND` | — | +30/−30 s |
| `MEDIA_NEXT`/`PREVIOUS` | next/previous channel | next/previous episode |
| `GUIDE` | open Live TV guide | — |
| `INFO` | toggle stats overlay (engine, codecs, resolution, bitrate, dropped frames) | same |
| `CAPTIONS` | cycle subtitles off → 1 → 2 … → off | same |
| `BACK` | chrome shown: hide it; strip shown: close it; else leave the player | same (saves progress) |
| number keys `0`–`9` | type a channel number (1.5 s timeout), tune if found | — |

Media keys must also work through `MediaSession` (Google Assistant "pause", "next").

## Chrome (TV)

Auto-hides after 5 s without input while playing. Never auto-hides while paused, ended, failed, while the user is
on the scrubber or a menu, or while the episodes strip is open (as `PlayerHost.chromePinned`). Pausing shows the
chrome. Layout (1920×1080 reference):

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ [logo] Title                                            [Audio] [Subtitles] [Info]
│        Subtitle · S2, E4 · 45 min                                             │
│                                                                               │
│                              (video)                                          │
│                                                                               │
│                         ⟲10     ▶/❚❚     10⟳                                   │
│  12:41 ━━━━━━━━━━━━━━━━━━━━━●───────────────────────────────── -32:10          │
│  [Episodes ▾]                                         [Skip Intro]            │
└───────────────────────────────────────────────────────────────────────────────┘
```

Live: no scrubber; programme progress bar with start/end times, "LIVE" badge, now/next titles. Loading: the
play/pause button becomes a spinner (no text). Failover/reconnect messages appear as a small pill top-centre.
