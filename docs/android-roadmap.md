# Android roadmap: what's done, what was deferred

Where the Google TV app (`android/`, shown as **Antenna**) stands against the phases in
`docs/superpowers/specs/2026-11-15-google-tv-design.md` → Phases, and everything that was knowingly left for later.
Swift is the reference for every item; check `docs/android-parity.md` for deliberate differences before porting.
Tick items here when they land, in the same commit.

## Usable today (end of phase 3, 2026-11-17)

Checked on the Google TV emulator and the owner's TCL TV (32-bit, 2.4 GB RAM) against the test kit:

- **Add a playlist**: type it in with the remote, or scan the QR code with a phone and fill in the page it opens.
  M3U, Xtream and Stalker. The phone page is plain HTTP on the LAN, protected by a one-time token.
- **Sync**: the first sync runs when the playlist is added, and stale sources refresh 3 s after launch. Passwords are
  encrypted with an Android Keystore key.
- **Browse**: Home shelves (Continue Watching, recent, favourites), Live TV (groups, then channels), Movies and Series
  grids by category, movie and series detail pages, Search, Favorites.
- **Play**: live channels (TS first, then HLS) with channel up/down; movies and episodes with resume, progress
  saving and Up Next.

## Next: closest to daily use

In order of how much a viewer would miss them:

1. ~~**Send to TV from Antenna on iPhone/iPad**~~ done 2026-11-17 (`PlaylistShare`, Settings → Playlists → "…" →
   Send to TV…). Checked with Swift's JSON against the emulator and the TCL TV; still to check by scanning the TV's
   QR code with Antenna on the owner's iPhone.
2. ~~**TCL TV pass**~~ done 2026-11-17 (`docs/android-devices.md`): 413 ms cold start, 38 MB PSS browsing, 50 MB PSS
   live TS, 60 MB PSS 4K HEVC + AC-3 (hardware `c2.mtk.hevc.decoder` and audio HAL AC-3 offload), 67 MB PSS movie.
3. ~~**Guide**~~ done 2026-11-17: XMLTV and Stalker ingest into Room (`epgFeed`, `epgChannel`, `program`), EPG key
   resolution, now/next and progress bar on the channel list, the TV Guide grid with 2-hour windows, and catchup
   playback (`PlaybackItem.Catchup`).
4. ~~**Player controls**~~ done 2026-11-17: an options panel (▼ with the controls up on movies and episodes; hold OK
   or the menu/info/captions key on live TV) with Audio, Subtitles, Picture (the Apple aspect choices) and Sleep
   Timer (`SleepTimer` ported with its tests, volume fade, "when this ends"). Skip Intro / Credits / Recap button from
   `SkipSegmentService` (button mode only; Settings → Playback's automatic mode comes with the settings work).
5. ~~**Live robustness**~~ done 2026-11-17: `LiveWatchdog` (the Apple watchdog's rules, tested) notices a stalled,
   ended or dropped live stream; the player fails over to the same channel in another playlist
   (`Library.alternateChannels`, as in Swift), else reconnects with 1–5 s backoff up to 10 times, with a notice.
   Still to do: `EngineMemory` (with the mpv engine), stall timeout / attempts / auto-failover in Settings.
6. **Settings**: partly done 2026-11-17. Settings now has Playlists (Refresh; Remove asks first), Playback (live
   stream format, automatic failover, resume, autoplay next episode, Up Next countdown, skip intro and credits:
   button / automatic / off) and Guide & Library (refresh intervals), stored in SharedPreferences with the Apple
   names and defaults (`Prefs.kt`; DataStore wasn't needed). Still to do: edit/rename a playlist, quick reopen time,
   metadata on/off, parental controls, user agent, stall timeout and attempts.
7. ~~**Organise**~~ mostly done 2026-11-17: long press on a channel (favourite, rename, hide) or a category in Live
   TV, Movies or TV Shows (rename, hide); Settings → Hidden shows them again. A hidden category hides its titles
   everywhere, as in Swift. Still to do: custom groups (tables exist since v2) and reordering categories.

## Phase 4 leftovers: player

- **mpv fallback engine** (LGPL libmpv, 32-bit and 64-bit ARM builds) for streams ExoPlayer can't open, plus the
  FFmpeg audio extension for AC-3/DTS on devices without decoders. The TCL decodes nearly everything in hardware,
  so this waits for a real failing stream.
- Quick reopen (keep a closed movie ready for 2 minutes, see android-parity.md).
- Remote mapping audit: number keys to tune, Info key for the chrome, long-press seek acceleration.

## Phase 6: Google TV integration and polish

- Watch Next row (Continue Watching on the home screen), MediaSession (Assistant "pause", the system's now-playing
  UI), deep links from Watch Next into the player.
- Voice search through the system search intent.
- Focus audit on every page, banner and launcher icon review, low-RAM tuning (Coil memory cache, list prefetch),
  metadata (posters, ratings) shown wherever the Apple apps show them.
- Background refresh with WorkManager instead of on launch only.
- Backup rules: exclude the database and the Keystore-encrypted passwords from cloud backup.

## Tests and tooling owed

- Room DAO tests on a device or Robolectric, including the Continue Watching database suite
  (`SmartContinueWatching` logic is tested; its queries are not).
- Run the shared vectors on a device too: Android's ICU regex and Unicode tables differ from the desktop JVM.
- Benchmarks on the TCL: sync time for a large playlist, list scroll, cold start, memory.
- A UI smoke test script for the emulator (the `scratchpad` scripts used during phase 3 were throwaway).

## Phase 7: store

- Play listing as Antenna, privacy policy (adapt `docs/app-store/privacy.md`), Data safety form, acknowledgements
  and licences screen, screenshots from the test kit only. Release signing stays with the owner.
- Fire TV pass (same APK, check the remote and the store's rules).
- Docs: README → Google TV section, `docs/design.md`, `docs/testing.md`, `CLAUDE.md`.

## Later features (after v1)

The Apple apps have these; the spec's non-goals keep them out of v1: on-device recommendations and natural search,
Top 10, smart guide matching, downloads, sync with the Apple apps, reminders, audio enhancements, IMDb ratings,
trailers, learned intros (`SkipLearner`).
