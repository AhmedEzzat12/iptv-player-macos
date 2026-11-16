# Appendix D — TV UI, settings, setup, Google TV integration

Part of the Google TV design (`../2026-11-15-google-tv-design.md`). Behaviour reference: `Sources/Tuner/Views/**`
and `Sources/Tuner/App/**`; look at `docs/media/*.png` for the Apple look. The TV UI is **designed for the remote**,
not translated: same information and behaviour, laid out for 10-foot viewing.

## Global rules

- Compose for TV (`androidx.tv:tv-material`) + Compose Foundation lazy layouts. Reference canvas 1920×1080 dp
  scaled (TV density); overscan-safe margins: 48 dp left/right, 27 dp top/bottom.
- Dark theme only. Background `#0B0B0D`; surfaces `#1A1A1E`; text primary `#FFFFFF`, secondary `#FFFFFF` at 60%.
  Accent from `accent` preference (default cyan `#00D4FF`, other values from `AccentTheme` in `Preferences.swift`).
- Type: system sans (Roboto/Google Sans as available). Sizes: page title 48 sp, row title 28 sp, card title 20 sp,
  body 18 sp, caption 16 sp. Nothing below 16 sp.
- **Focus**: the focused card scales to 1.08 with a 3 dp white border and a soft glow; focused buttons fill white
  with dark text (TV Material defaults). Focus must always be visible. On every navigation, focus lands on the most
  useful element (listed per screen). Returning Back restores focus to the element that opened the page
  (`FocusRequester` + `rememberSaveable` key per page).
- Lists are lazy (`LazyRow`/`LazyColumn`/`LazyVerticalGrid`) with stable keys (ids from Appendix B).
- Images: Coil with size-limited requests (poster 300×450 px, backdrop 1280×720, logo 200×200); placeholders are
  surface-coloured blocks with the title text, never spinners.
- Long-press OK (or the menu key) opens a context menu on cards (channel: Favourite, Hide, Add to Group, Rename;
  movie/show: Favourite, Mark Watched/Unwatched, Remove from Continue Watching).
- Strings: English only in v1 (the Apple apps are English-only), all in `strings.xml` so translation is possible.
  The visible app name comes from one resource (`Antenna`); code stays "Tuner".
- RTL: playlist content can be Arabic; text views use `TextDirection.Content` so mixed Arabic/English titles render
  correctly. Layout stays LTR.

## Navigation shell

Left `NavigationDrawer` (TV Material), collapsed to icons (72 dp), expands to icons + labels (280 dp) when focused.

Items, in order: **Search** (magnifier) · **Home** · **Live TV** · **Movies** · **TV Shows** · **Favorites** ·
(spacer) · **Settings** (gear). Default selection on launch: Home (or Live TV and the last channel playing, if
`resumeLastChannelOnLaunch` and the last session ended in live TV).

- Each section keeps its own back stack (Navigation Compose nested graph per section). Selecting the open section
  again pops it to its top page (Swift: `sectionRootRequests`).
- Back on a section's top page moves focus to the drawer; Back on the drawer exits the app (no confirmation).
- `GUIDE` key anywhere → Live TV.

## Welcome (first run, no sources)

```
            Antenna
   Watch your IPTV playlists on your TV.

   [  Add a Playlist  ]   ← focused
   [  Type It In Instead  ]

   You're responsible for the playlists you add. Antenna doesn't provide any channels or content.
```

"Add a Playlist" → QR setup. "Type It In Instead" → the on-TV source editor.

## QR setup (add or fix a playlist from a phone)

Screen:

```
  Add a Playlist
  Scan with your phone's camera:            ┌──────────┐
                                             │  QR code │
  or open  http://192.168.1.23:8790/k7Q2x    └──────────┘
  on a phone or computer on the same Wi-Fi.

  Waiting for your phone…                    [ Type It In Instead ]  [ Cancel ]
```

- Server: starts when the screen opens, binds the device's Wi-Fi/Ethernet IPv4 address on a free port (try 8790,
  then any), stops when the screen closes. If there's no network, show "Connect the TV to your network" and only the
  type-it-in option.
- Token: 128-bit random, base62, in the path (`/<token>`); requests without it get 404. Valid for one successful
  submission or 10 minutes; a wrong token 5 times in a row stops the server and asks to start over.
- Page (served from the app, no external resources, works on phone browsers): fields as the Apple source editor
  (`SourceEditorView.swift`): Name; Type (M3U URL / Xtream Codes / Stalker Portal); for M3U: URL, guide URL
  (optional); Xtream: server URL, username, password (or "paste a `get.php`/`player_api.php` link", parsed with
  `XtreamClient.parseCredentials`); Stalker: portal URL, MAC (format check `XX:XX:XX:XX:XX:XX`); advanced (collapsed):
  user agent, extra guide URLs, guide time shift, include live / include movies & shows, backup URLs. Submit →
  POST (form-encoded) to the same token path.
- After POST: the page shows "Sent to your TV"; the TV shows a confirmation card with the name, type and host (never
  the password) and **[Add Playlist]** (focused) / **[Discard]**. Add runs `SyncService.test`, then saves and starts
  the first sync with progress ("Loading channels… 12,340", "Loading movies…").
- Fix mode (a source with `needsPassword` or an auth error): the same screen, page pre-filled with everything except
  the password, title "Update <name>".
- The page is plain HTTP on the LAN (decision in the design). No analytics, no external fonts or scripts.

## Source editor on the TV (type it in)

Same fields as the QR page, as TV text fields (on-screen keyboard); one field per row; D-pad down moves through
fields; [Test] (runs `SyncService.test`, shows the result inline: account status, expiry, connections) and [Save].

## Home

Top: hero (480 dp tall) rotating every 8 s through up to 6 featured titles (recently added with backdrops, else top
rated), with title logo (metadata) or title text, year · genre · rating, one-line plot, and buttons **[Play]**
(focused on first launch of the page) **[More Info]**. Left/right on the hero buttons do nothing (focus stays);
the hero advances on its own; Down goes to the first row.

Rows, in this order (same as `HomeView.swift`), each hidden when empty:

1. **Continue Watching**: `smartContinueWatching` resume entries; landscape cards (backdrop) with a progress bar,
   title, subtitle ("S2, E4 · Title" or year). OK resumes playback directly (no detail page). Context menu: Mark
   Watched, Remove from Row (deletes progress), Go to Show/Movie.
2. **Up Next**: next-episode entries from `smartContinueWatching`; card subtitle `S2, E5 · Next Episode`. OK plays
   from the start.
3. **On Now**: favourite channels (else recently watched) with the current programme: logo, channel name, programme
   title, progress through the programme. OK tunes (opens the player full screen).
4. **Recently Added Movies**, 5. **Recently Added Shows**, 6. **Top Rated**, 7. **Your Favorites** (VOD favourites):
   poster cards (2:3), OK opens the detail page.

Initial focus: the first card of Continue Watching if present, else the hero's Play.

## Live TV

```
┌ preview 16:9 (≈ 640×360) ┐  Channel name · 101
│  live video (muted? no)  │  NOW  News at Nine           21:00–22:00  ━━━━━━──
└──────────────────────────┘  NEXT Weather                22:00–22:15
[All] [Favorites] [Recently Watched] [News] [Sports] [Kids] …        Playlist: ▾
┌──────────┬───── 21:00 ─────┬───── 21:30 ─────┬───── 22:00 ─────┬────────────
│ 101 CNN  │ News at Nine                       │ Weather │ Sports Tonight
│ 102 BBC  │ World News      │ Panorama                  │ …
```

- Category chips: All, Favorites, Recently Watched, custom groups, then the provider's live categories (hidden ones
  excluded, user order/aliases applied). Playlist picker when there are several sources.
- Guide grid: sticky time ruler (30-minute ticks) and channel column (logo, number if `showChannelNumbers`, name),
  now-line, cells sized by duration (1 hour = 480 dp), programmes from `programs(epgKeys, from, to)` paged by a
  6-hour window loaded around the visible time; scrolling right past the window loads the next window. Past
  programmes on channels with catchup show a ⟲ marker.
- Focus moves cell to cell: Left/Right along time (moving the time window as needed), Up/Down to the same time on the
  neighbour channel. Initial focus: the current programme of the last-watched channel (else the first channel).
- Focusing a channel's cell plays it in the preview after 600 ms of rest (debounced so scrolling doesn't zap through
  channels). OK on a current programme opens the player full screen; OK on a past programme with catchup plays it
  from the archive (`StreamResolver.catchup`, padding `catchupPaddingMinutes`); OK on a future programme shows its
  details.
- Channels without guide data show one cell "No information" spanning the window.
- Channel context menu (long-press): Favourite, Hide, Rename, Add to Group, Choose Guide Channel (picker searching
  `epgChannels(matching)`, sets `epgIdOverride`).
- `CHANNEL_UP/DOWN` on this screen moves the focus by one channel.

## Movies / TV Shows

- Top: page title, then a chip row: the pinned categories (from `pinnedCategoryIds`), then menu chips from
  `CategoryGrouping` (Featured, Languages & Countries, Platforms, Genres, By Year, Sports, Kids, Quality, More;
  each opens a vertical list of its categories), then **Categories…** (organiser: pin/unpin, hide/show; name style
  Automatic / Arabic / Original = `categoryNameStyle`).
- Grid: posters (2:3, 6 per row at 1920 dp), paged 120 at a time with `movies(categoryId, sort, limit, offset)`;
  sort menu (Recently Added default, Name, Year, Rating, Provider order = `vodSort`).
- Initial focus: first poster.

### Movie detail

Backdrop full-bleed (dimmed bottom-left gradient), title logo or title, year · duration · rating · genre, plot
(4 lines, "More" opens the full text), cast and director, where it's listed ("Playlist › Category"). Buttons:
**[Resume 12:40]**/**[Play]** (focused), [Play from Beginning] (when there's progress), [♥ Favourite],
[Mark Watched]. Details come from the provider (`get_vod_info`, stored) and metadata (logo, backdrop, cast).

### Show detail

Same header with the show's info. Buttons: **[Resume S2, E4]** / **[Play S1, E1]** / **[Play Next Episode]**
(per `SmartContinueWatching`'s choice for the show), [♥ Favourite], [Mark Show Watched] (asks to confirm).
Below: season chips (Season 1, 2, …; initial = the season of the episode to resume) and a row of episode cards
(16:9 still per `episodeThumbnails` style: show / blur unwatched / hide; title, `E4 · 45 min`, progress bar,
watched check). OK plays the episode (resume if in progress). Context menu: Mark Watched (offers to mark earlier
episodes too, as Apple), Mark Unwatched. Season chip context: Mark Season Watched/Unwatched. Episodes are fetched
on open (`get_series_info`) and stored; stored ones show immediately.

## Search

- Field at the top with the on-screen keyboard; mic button (if `SpeechRecognizer.isRecognitionAvailable`) using
  `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` (free-form, device language). The remote's mic button while on this
  screen starts voice input too.
- Results update 300 ms after typing stops: rows **Channels** (name match), **On TV** (`searchPrograms`, now and the
  next 72 h), **Movies**, **TV Shows** (name match, up to 200 each).
- Recent searches (`recentSearches`, max 12, case-insensitive dedupe, newest first) shown while the field is empty;
  a search is recorded when submitted or when a result is opened/played (`Preferences.addRecentSearch` rule).

## Favorites

Favourite channels (in favourite order; reorder mode via context menu "Move"), custom groups as sections, and VOD
favourites (movies, shows).

## Settings

A list on the left, the selected pane on the right (TV Material `ListItem`s). Panes and the preferences they edit
(keys exactly as `Preferences.swift`, stored in DataStore):

| Pane | Setting (key) | Values (default) |
|---|---|---|
| **Playlists** | list of sources: status (channels/movies/shows counts, last sync, expiry, connections, error), [Refresh], [Edit] (QR or type), [Remove] (confirm), [Add a Playlist] | — |
| | Guide feeds: global XMLTV URLs (add via QR page "Guide URL" mode or typing), per-source extra feeds and time shift in the source editor | — |
| **Playback** | Player engine (`engine`) | Automatic / mpv / ExoPlayer (`automatic`) |
| | Hardware decoding (`hardwareDecoding`) | on |
| | Buffer size MB (`bufferMegabytes`) | 50/100/150/250 (150) |
| | Resume where I left off (`resumePlayback`) | on |
| | Play next episode automatically (`autoplayNextEpisode`) | on |
| | Up Next countdown (`upNextCountdown`) | Off/5/10/15/20/30 s (10) |
| | Skip Intro & Credits (`skipSegments`) | Button / Automatic / Off (`button`) |
| | Keep a closed movie ready (`keepWarmMinutes`) | Off/2/5/10 min (**2** on TV) |
| | Catchup padding (`catchupPaddingMinutes`) | 0/1/2/5 min (0) |
| | Switch to a backup channel when one fails (`autoFailover`) | on |
| | Stall timeout (`stallTimeoutSeconds`) | 8/12/20/30 s (12) |
| | Reconnect attempts (`maxRetries`) | 3/5/10/20 (10) |
| | Show stream speed (`streamSpeedDisplay`) | Always / With controls (`withControls`) |
| | Default user agent (`defaultUserAgent`) | text ("" = `VLC/3.0.20 LibVLC/3.0.20`) |
| **Guide & Library** | Channel order (`channelSort`) | Provider / Name / Number (`provider`) |
| | Show channel numbers (`showChannelNumbers`) | off |
| | Channel banner when zapping (`showChannelBannerOnZap`) | on |
| | Hide adult content (`hideAdultContent`) | off |
| | Refresh live TV every (`liveRefreshHours`) | 0 (manual)/3/6/12/24 h (6) |
| | Refresh movies & shows every (`vodRefreshHours`) | 0/12/24/48 h (24) |
| | Resume last channel on launch (`resumeLastChannelOnLaunch`) | on |
| | Clear recently watched | action |
| **Metadata** | Online artwork & info (`metadataEnabled`) | on |
| | TMDB API key (`tmdbAPIKey`) | text, typed or via the QR page ("TMDB key" mode); empty = Cinemeta |
| | Language (`metadataLanguage`) | device `language-REGION` |
| | Episode pictures (`episodeThumbnails`) | Show / Blur unwatched / Hide (`show`) |
| **Appearance** | Accent colour (`accent`) | cyan, blue, purple, crimson, orange, green, gold (`cyan`) |
| | Category names (`categoryNameStyle`) | Automatic / Arabic / Original (`automatic`) |
| | Movie & show sort (`vodSort`) | as above (`added`) |
| **About** | version (`versionName (versionCode)`), Acknowledgements (libraries + licences, LGPL text), privacy note, "You're responsible for the playlists you add" | — |

Not on TV (Apple-only or not in v1): `mouseSwipes`, `pull*`, `recordingsPath` and recording paddings,
`downloadsPath`, `shortcutOverrides`, `followSystemAppearance`, `timeshiftMegabytes`, `mpvExtraOptions` (could be
added later as an advanced field), AI toggles, Top 10, audio enhancements, reminders (`reminderLeadMinutes`),
`posterSize`, `volume` (the TV's own volume is used; engines run at 100).

## Google TV integration

- **Launcher**: `LEANBACK_LAUNCHER` intent filter, `android:banner` 320×180 px (app name on a dark background with
  the accent mark), app icon. `<uses-feature android:name="android.software.leanback" android:required="true"/>`,
  `android.hardware.touchscreen required="false"`, `android.hardware.microphone required="false"`.
- **Watch Next** (`androidx.tvprovider.media.tv.WatchNextProgram`, `TvContractCompat`): publish entries for
  `smartContinueWatching` (resume entries as `WATCH_NEXT_TYPE_CONTINUE` with `lastPlaybackPositionMillis` and
  `durationMillis`; next episodes as `WATCH_NEXT_TYPE_NEXT`), poster = backdrop, title/subtitle as the Home cards,
  `internalProviderId` = media id, intent URI `antenna://play/<movie|episode>/<id>` (deep link opens and resumes).
  Update after each progress save (debounced 30 s) and when Continue Watching changes; remove finished or removed
  items. On `ACTION_WATCH_NEXT_PROGRAM_BROWSABLE_DISABLED` (the user removed the entry from Google TV), keep the
  app's own progress but stop republishing that id until it's played again. Skip silently when the provider isn't available
  (Fire TV, older Android TV).
- **MediaSession**: Media3 `MediaSession` bound to the active engine's player (ExoPlayer directly; mpv through a
  `SimpleBasePlayer` adapter) so Assistant and the remote's media keys work, and "Now Playing" metadata shows title
  and artwork.
- **Deep links**: `antenna://play/channel/<id>`, `antenna://play/movie/<id>`, `antenna://play/episode/<id>`,
  `antenna://title/<movie|series>/<id>`; unknown ids open Home with a toast "This title is no longer in your
  playlists".

## Empty and error states

| Situation | What shows |
|---|---|
| No sources | Welcome |
| Source syncing first time | Home rows replaced by "Loading <name>… <count> channels" with progress |
| Sync failed | Settings → Playlists shows the error under the source; a banner on Home "Couldn't refresh <name>" with [Retry], once per launch |
| Needs password | Source shows "Password needed" with [Update] (QR fix mode) |
| Category empty | "Nothing in this category" |
| Guide missing for all channels | Live TV shows the channel list with "No guide information" cells and a hint "Add a guide in Settings → Playlists" |
| Playback failed | Player card: the message from routing (incl. the 503 wording), [Try Again] (focused), [Back] |
| Offline | Banner "No internet connection"; library browsing works from the database |
