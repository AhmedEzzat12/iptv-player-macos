# ynotv — how it works (reference for the Tuner port)

Studied from `github.com/tbeezy/ynotv` @ v2.5.6 (Tauri v2 + React 19 + Rust + libmpv, Windows-first, AGPL-3.0).
No code was copied; this is a behavioural reference.

## Repository shape

| Package | Role |
|---|---|
| `packages/app/src-tauri` | Rust: libmpv embedding (`mpv_core.rs`, `mpv_render_mac.rs`), native M3U/Xtream sync (`sync_provider.rs`), streaming XMLTV parser (`epg_streaming.rs`), DVR (`dvr/*`), popout mpv, casting |
| `packages/local-adapter` | TS fallbacks: M3U parser, Xtream client, Stalker client, M3U catchup URL builder |
| `packages/ui` | React app: SQLite schema (`db/index.ts`), sync orchestration (`db/sync.ts`), zustand stores, all views |
| `packages/core` | Shared TS types |

## Sources

- **M3U**: `#EXTM3U url-tvg|x-tvg-url` (EPG), header catchup defaults; `#EXTINF` attributes `tvg-id`, `tvg-name`, `tvg-logo|tvg-icon|logo`, `group-title|group`, `tvg-chno`, `catchup*`, `timeshift|tvg-shift`. Display name = text after the last comma. Ignores `#EXTVLCOPT`/`#KODIPROP`; drops non-http entries.
- **Stable ids**: channel `{src}_{sanitized tvg-id}` → on collision `…_{djb2(url)}` → `…_{n}`; no tvg-id → `{src}_url_{djb2(url)}`. Category `{src}_{slug(name)}`.
- **Xtream**: `player_api.php?username&password[&action]`; actions `get_live_categories`, `get_live_streams`, `get_vod_categories`, `get_vod_streams`, `get_series_categories`, `get_series`, `get_series_info` (on open), `get_vod_info` (lazy). Live URL `/live/u/p/{id}.ts`, movie `/movie/u/p/{id}.{ext}`, episode `/series/u/p/{epId}.{ext}`. EPG `xmltv.php`. Ids: `{src}_{id}`, `{src}_vod_{id}`, `{src}_series_{id}`.
- **Stalker** (MAG portal): endpoint discovery (`/portal.php`, `/stalker_portal/server/load.php`, `/c/`), MAG250 headers + `Cookie: mac=…`, handshake → token → `get_profile` (sn = MD5(mac)[0:13], device_id = SHA256(mac), signature = SHA256(mac+sn+id+id2)); `itv get_genres/get_all_channels`, `vod/series get_categories/get_ordered_list` (paged, 14/page), `create_link` at play time (strip `ffmpeg `/`ffrt ` prefix, fix localhost hosts), `get_epg_info` for guide, `account_info get_main_info` for expiry.
- **Sync**: full replace with stable-id upserts that preserve user columns; stale rows deleted. Backup server URLs tried in order on failure; the working one is promoted. Auto refresh: live/EPG 6 h, VOD 24 h, checked every 10 min.
- **Known quirks** (fixed in Tuner): sticky `error` flag, `last_synced` stamped on failure (no retry), favourites lost if a channel disappears for one sync, credentials not URL-encoded, EXTINF + non-http URL silently dropped.

## EPG

- Streaming XMLTV parse (quick_xml), gzip detected by magic bytes (`1f 8b`), multi-member gzip. Only `title`, `sub-title`, `desc` kept. Dates `YYYYMMDDHHmmss ±HHMM` → UTC.
- Data is buffered and only committed if the download completed (keeps old guide on failure).
- Matching per programme: tvg-id (exact, lowercased) → raw name → normalised name (strip `prime: il: [ ] ( )`, superscripts, keep alnum and `+`, lowercase). Additional EPG URLs and global feeds fill gaps for channels with no current data.
- Per-source and per-channel time shift applied at read time.
- Catchup: Xtream `/timeshift/u/p/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts` with start converted to server-local time (`server_info.time_now` − `timestamp_now`). M3U: `append` `?utc=S&lutc=NOW`, `shift` `?utc=S`, `flussonic` `video-S-D.m3u8`, default `?start=S`; `catchup-source` templates with `{utc} {start} {end} {duration} {offset} {Y}{m}{d}{H}{M}{S}` etc.

## Guide UI

- Time grid: 200 px/hour target, 2–5 visible hours, anchored at the current hour; channel column 264 px; now-line; program cells clamped to the next program's start; second text line only when wider than 200 px.
- Top section: preview pane (54 % width, video is moved into it) + info pane (title, times, progress, description).
- Row click previews; second click within 500 ms goes fullscreen. Past program on archived channel → catchup.
- Alternate views: preview-only, 3-column (channel strip + schedule list).

## Player

- libmpv render API (OpenGL on macOS). Options: `keep-open`, `idle`, `hwdec=auto`, `cache=yes`, demuxer back-buffer for timeshift (256 MB), `user-agent` per stream, `network-timeout`. Track lists via `track-list`, `aid`/`sid`; stats via stats.lua.
- Watchdog every 1 s for live streams: 5 s grace after load; stream is dead if EOF, idle without progress, cache starvation > ~3.5–5 s, or no progress for 10 s. Then: failover group (next priority, rotate to primary once) → retry with backoff (max 20).
- Multiview: `main`, `pip` (480×270 overlay), `bigbottom` (main + 3 below), `2x2`, `sbs`. Only main has audio; clicking a cell swaps it with main.
- DVR: one `ffmpeg -user_agent UA -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -i URL -c copy -t DUR out.ts` per recording; scheduler polls every 30 s with 60 s start padding / 300 s end padding; stop via `q` on stdin; filename `{date}_{channel}_{title}.ts`.
- Reminders: 10 s scheduler; notify N min before; optional auto-switch at start.

## Shortcuts (defaults)

Space play/pause · M mute · J subtitles · A audio · I stats · F fullscreen · G/L guide · C categories · R DVR · , settings · S search · Esc back · ←/→ seek 10 s · ↑/↓ channel · 1–4 layouts · E EPG view · Q last channel · Z transparent guide · / help.

## Out of scope for the port

Stremio, Nuvio, Jellyfin, Trakt, Simkl, Discord, Sports, TV calendar (TVMaze), phone remote, gamepads, 24 locales, Chromecast, TMDB/RPDB enrichment, local library, playlist editor, EPG editor UI.
