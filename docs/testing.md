# End-to-end testing with the local test kit

The test kit runs Tuner against realistic, fully local providers: an extended-M3U playlist with an XMLTV
guide, and an Xtream Codes panel. Nothing touches the internet. Every channel, movie and episode has its
name burned into the picture in large letters, plus a running timecode and a distinctive beep. That way you
can tell at a glance which stream is playing and whether it is moving.

| Path | What it is |
|---|---|
| `scripts/testkit/make_media.sh` | Generates the media into `TestMedia/` (git-ignored) with `/opt/homebrew/bin/ffmpeg` |
| `scripts/testkit/server.py` | Python 3 stdlib-only HTTP server on `127.0.0.1:8765` that serves the playlist, guide, Xtream API and streams |

## 1. Generate the media (once)

```sh
scripts/testkit/make_media.sh
```

A first run takes about 75 s and writes about 92 MB. The script is idempotent: files that already exist are skipped. To rebuild
something, delete it (or the whole `TestMedia/`) and run the script again. Optional overrides: `FFMPEG=/path/to/ffmpeg` and
`TESTKIT_MEDIA=/other/dir` (the server reads the same variable).

What it creates:

- `channels/feed{1-4}-*.ts`: four 64 s, 1280x720 25 fps H.264 + AAC "channel" clips. 64 s is exactly 1600 video frames and 3000 AAC
  frames, so the loop is seamless.
- `hls/feed{1-4}/`: the same clips cut into 2 s HLS segments (VOD playlists).
- `movies/`: three 90 s movies. `1001` is a plain MP4 (+faststart). `1002` is an MP4 with 2 audio tracks and 2 `mov_text`
  subtitle tracks. `1003` is an MKV with 2 audio tracks and 2 SRT subtitle tracks.
  Plus four 60 s MP4s titled after the Blender Foundation's open movies (`1004`–`1007`: Big Buck Bunny, Sintel, Tears of
  Steel, Elephants Dream; CC BY) in the "Open Movies (CC BY)" category. The files are synthetic clips; the real titles
  let online metadata match them. TMDB finds them, but Cinemeta's search doesn't index them, so without a TMDB key
  they correctly show "no match".
- `series/`: two series, each with 2 seasons of 3 episodes (30 s each, `SxxEyy` and title burned in).
- `img/`: posters (400x600), backdrops (1280x720), episode stills (640x360) and channel logos (400x400; News and Movies are
  solid, Sports and Kids are transparent).

This ffmpeg build has no `drawtext` (no libfreetype), so a small bitmap-font renderer inside the script draws all text to PNG,
and ffmpeg's `overlay` composites it. The script imports its titles from the catalog in `server.py`, so the picture always matches
what the playlist and API report.

## 2. Start the server

```sh
python3 scripts/testkit/server.py            # http://127.0.0.1:8765
python3 scripts/testkit/server.py 9000       # other port (or TESTKIT_PORT=9000)
TZ=America/New_York python3 scripts/testkit/server.py   # pretend the Xtream panel is in another timezone
```

Open <http://127.0.0.1:8765/> for a summary of the endpoints. The server logs one line per request, with the User-Agent and
what the request resolved to. Live streams log a second line when they end:

```
17:54:49  403 GET  /ua/3.ts [Forbidden: User-Agent must contain 'TunerTestKit' (referer missing)]  UA=Lavf/61.7.100
17:54:49  200 GET  /ua/3.ts [ua-locked: UA ok, referer ok; feed=3 live-ts join=1.7s behind live, loop 57]  UA=TunerTestKit/1.0 ...
17:55:21  200 GET  /timeshift/test/test/30/2026-10-01:17-25/1.ts [xtream timeshift 1 feed=1 archive start=2026-10-01 14:25:00 UTC (server-local 2026-10-01 17:25) dur=30min 52.6MB]
17:55:20  END /stream/1.ts: 70.1s, 2.1MB (client closed)
```

Stop it with Ctrl-C.

## 3. Add the sources in Tuner

**M3U source**
- Playlist URL: `http://127.0.0.1:8765/playlist.m3u`
- EPG: picked up automatically from the header (`url-tvg="http://127.0.0.1:8765/epg.xml.gz"`). If you need to enter it by hand,
  use `http://127.0.0.1:8765/epg.xml.gz` (gzip) or `http://127.0.0.1:8765/epg.xml` (plain).

**Xtream Codes source**
- Server: `http://127.0.0.1:8765`
- Username: `test`
- Password: `test` (any other credentials get `{"user_info":{"auth":0}}`, and media and EPG URLs return 401)
- EPG: `http://127.0.0.1:8765/xmltv.php?username=test&password=test` (what Tuner derives on its own)
- To test "paste a link": `http://127.0.0.1:8765/get.php?username=test&password=test&type=m3u_plus&output=ts`. This is also a
  complete M3U of the Xtream catalog. Use `output=m3u8` for HLS live URLs.

## 4. Telling the channels apart

There are four "feeds" (broadcast clips). Each one shows its name in a big top banner, a `HH:MM:SS:FF` clip timecode at the
bottom, and a bar that sweeps left and right (so stutter is easy to see). Each also beeps once per second at its own pitch:

| Feed | Burned-in name | Background | Beep | tvg-id / epg_channel_id |
|---|---|---|---|---|
| 1 | TUNER NEWS | animated blue gradient | 440 Hz | `news.tuner` |
| 2 | TUNER SPORTS | `testsrc2` pattern | 554 Hz | `sports.tuner` |
| 3 | TUNER MOVIES | SMPTE HD colour bars | 659 Hz | `movies.tuner` |
| 4 | TUNER KIDS | orange cellular automaton | 880 Hz | `kids.tuner` |

The live streams follow the wall clock like a real broadcast. The channels went "on air" one hour before the server started, so
every client tuning in sees the same moment. Two players on the same channel show the same timecode, to within the
1–3 s start-up burst. The clip loops every 64 s and the timecode wraps with it. On each loop the server rewrites PTS, DTS, PCR
and continuity counters, so the stream never jumps backwards and no discontinuity is signalled.

## 5. M3U playlist: what each entry exercises

| # | Name in list | Group | URL | Exercises |
|---|---|---|---|---|
| 101 | Tuner News | News | `/stream/1.ts` | Raw MPEG-TS live; catchup `append` (`?utc={utc}&lutc={lutc}`, 3 days) |
| 102 | Tuner News (Backup HLS) | News | `/stream/1.m3u8` | Live HLS; same tvg-id as 101, so it is a failover alternate |
| 103 | Tuner News (Flaky - stalls after 20s) | News | `/flaky/1.ts` | Sends 20 s of live TS, then stops sending but keeps the socket open for 60 s. Tests the watchdog "no progress" detection and failover to 101/102. Its logo URL is deliberately a 404 (tests the logo fallback). |
| 201 | Tuner Sports | Sports | `/stream/2.m3u8` | Live HLS sliding window (6 x 2 s, `PROGRAM-DATE-TIME`); catchup returns a VOD HLS playlist |
| 202 | Tuner Sports 4K (Dead - 404) | Sports | `/dead/2.ts` | Always 404. Same tvg-id as 201, so failover should land on Tuner Sports. |
| 301 | Tuner Movies (UA locked) | Entertainment | `/ua/3.ts` | `#EXTVLCOPT:http-user-agent=TunerTestKit/1.0 (UA-locked channel)` plus `http-referrer=http://tuner.test/`. The server returns **403 unless the User-Agent contains `TunerTestKit`**. The Referer is only checked in the log (`referer ok` / `missing` / `WRONG`). |
| 302 | Tuner Kids | Entertainment | `/stream/4.ts` | Raw TS + catchup. `tvg-name="Tuner Kids, Family & Fun"` has a comma inside a quoted attribute. |
| – | Big Buck Test (2021), Matroska Nights (2019) | Movies | `/movie/test/test/1001.mp4`, `/1003.mkv` | `/movie/` lines are routed into the VOD library, with the year split from the title |
| – | Signal Lost S01 E01..E03 | Series | `/series/test/test/2101.mp4`… | `/series/` + `SxxEyy` names are grouped into a series |

The guide (`/epg.xml[.gz]`) is generated at request time for every tvg-id. It runs from now−12 h to now+36 h with no gaps, in
30, 45 and 60 min programmes. Programmes have titles, sub-titles, descriptions, categories, icons (on about a third), `xmltv_ns` and
`onscreen` episode numbers, `<credits>`, `<rating>` and `<new/>` / `<previously-shown/>`. One title,
`Q&A: Ask the <Experts>`, checks entity decoding. The schedule is a fixed function of each UTC day, so repeated downloads agree. Every
description states its own air time, e.g. `Airs 14:30-15:00 UTC (30 min)`, which lets you check the guide's timezone
rendering. The guide also has a guide-only `weather.tuner` channel that no stream carries.

## 6. Xtream catalog

| Kind | Id | Name | Notes |
|---|---|---|---|
| live | 1 | Tuner News | `tv_archive=1`, `tv_archive_duration="3"` (string) |
| live | 2 | Tuner Sports | `tv_archive=1`, `tv_archive_duration=3` (number) |
| live | 3 | Tuner Movies | no archive |
| live | 4 | Tuner Kids | archive 7 days |
| live | 5 | Tuner Sports 4K | **dead**: `/live/test/test/5.ts` returns 404; shares `epg_channel_id` `sports.tuner` with 2, so it exercises failover |
| movie | 1001 | Big Buck Test (2021) | plain MP4, has a `youtube_trailer` id (needs internet to actually play) |
| movie | 1002 | The Multitrack Mystery (2023) | MP4: audio `eng` (low single beep, 330 Hz) + `spa` (high double beep, 990 Hz); subtitles `eng` + `spa` (`mov_text`) |
| movie | 1003 | Matroska Nights (2019) | MKV: audio `eng` + `fre`, SRT subtitles `eng` + `fre`. **AVFoundation cannot open MKV.** Expect mpv to play it and AVFoundation to fail cleanly or fall back. |
| series | 1 | Signal Lost (2024) | episodes 2101–2106; `episodes` is a `{"1": [...], "2": [...]}` map; `episode_num` is a string |
| series | 2 | The Test Pattern Bakery (2022) | episodes 2201–2206; `episodes` is a list of lists (a real panel quirk); `episode_num` is a number |

Categories: live `1` News, `2` Sports, `3` Entertainment, `4` Empty Category (no streams); VOD `10`, `11`, `12` (empty);
series `20`, `21`. Other realistic quirks: numeric ids alongside string `category_id` / `rating` / `added`, PHP-style `\/`
escaped slashes, `is_adult` as `"0"` or `0`, and `category_id` filtering. `get_vod_info` / `get_series_info` with an unknown id
return `{"info":[],...}`. Unknown actions return `[]`. `active_cons` counts the live streams currently open. `get_short_epg` and
`get_simple_data_table` are implemented (base64 titles) even though Tuner does not use them.

Live URLs: `/live/test/test/<id>.ts`, `/live/test/test/<id>.m3u8`, and the short form `/test/test/<id>`. Movies are at
`/movie/test/test/<id>.<ext>`; any extension is accepted and the real file is served, which the log notes. Episodes are at
`/series/test/test/<id>.mp4`. All files support HTTP Range (206 / 416), which AVPlayer needs for MP4.

## 7. Catchup / timeshift

- **M3U (`append`)**: Tuner requests `/stream/<n>.ts?utc=START&lutc=NOW` (or `.m3u8?...`). When `utc` is more than 30 s in the
  past, the server returns the archive as a finite stream:
  - For `.ts`, a seekable MPEG-TS (`Content-Length` + Range) of `lutc − utc` seconds, capped at 3 h.
  - For `.m3u8`, a VOD HLS playlist (`EXT-X-ENDLIST`).
- **Xtream**: `/timeshift/test/test/<minutes>/<YYYY-MM-DD:HH-MM>/<id>.ts` (also `.m3u8` and `/streaming/timeshift.php`). The
  start time is read as **server-local time**. `server_info.time_now` is server-local and `timestamp_now` is UTC, which is how
  Tuner computes `serverTimeOffset`. To check the conversion, run the server with a different `TZ`, play a past programme, and
  compare the `archive start=… UTC` in the log with the programme's start in the guide (its description also states the
  UTC air time).
- Archive content is the feed as it was "broadcast" at that time, so the picture shows the same channel name. The proof that the
  right programme was requested is the logged start time and duration.

## 8. Suggested checklist

1. **M3U sync**: 7 channels in 3 groups plus 2 movies and 1 series (3 episodes). Logos appear, except Flaky's (404 → fallback).
2. **Guide**: all four channels show programmes; the "now" line lines up with the `Airs … UTC` text.
3. **Zapping**: TS (101, 302) and HLS (102, 201) start within a few seconds. The banner matches the channel you picked and the
   timecode and sweeping bar keep moving. On AVFoundation, raw `.ts` is not expected to play. Use the HLS entries or the Xtream
   `.m3u8` format.
4. **Failover**: play 202 (404) and expect a switch to 201. Play 103, wait about 20 s, and expect the watchdog to switch to 101 or 102.
5. **User-Agent**: play 301. It works only if the per-channel UA is sent; the log shows `UA ok, referer ok`.
6. **Catchup**: on 101/201/302 pick a past programme. The log shows `archive start=…` with the programme's UTC start, and the stream
   can be sought.
7. **Xtream**: log in. Expiry is about 30 days out and max connections is 2. Check 4 live channels with archive, the dead id 5, 3 movies
   with posters, backdrops, plot and duration, and 2 series with seasons and episode stills. Try both the `.ts` and `.m3u8` live formats.
8. **Tracks**: on movie 1002, switching audio changes the beep (low single ↔ high double), and the subtitles read `[ENG] Subtitle n` /
   `[SPA] Subtítulo n`. MP4 muxers always flag the first subtitle track as enabled, so English subtitles may show by default.
9. **Resume / seek**: movies and episodes show a frame-accurate timecode, so a resumed position is easy to verify.
10. **Bad credentials**: an Xtream source with password `nope` must fail login with a clear error.

## 9. Quick command-line checks

```sh
curl -s http://127.0.0.1:8765/playlist.m3u | head
curl -s http://127.0.0.1:8765/epg.xml.gz | gunzip | head
curl -s 'http://127.0.0.1:8765/player_api.php?username=test&password=test' | python3 -m json.tool
curl -s -D - -o /dev/null -H 'Range: bytes=0-1' http://127.0.0.1:8765/movie/test/test/1001.mp4   # 206
gtimeout 20 ffprobe -v error -show_entries stream=codec_name http://127.0.0.1:8765/stream/1.ts
ffprobe -v error -show_entries format=format_name http://127.0.0.1:8765/stream/2.m3u8
mpv http://127.0.0.1:8765/stream/4.ts
```

## Limitations

- No Stalker/MAG portal emulation, and no HTTPS.
- Only four distinct feeds. Backup, flaky and dead entries reuse them (the banner always names the feed).
- Credentials are fixed (`test` / `test`). Every Xtream account sees the same catalog.
- A 64 s loop means the visible timecode is clip time, not wall-clock time. Use the server log to verify catchup start times.
- The MKV movie needs mpv; AVFoundation playback of raw `.ts` URLs is not expected to work (use HLS).
