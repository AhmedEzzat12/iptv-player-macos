# Android test devices

Devices the Google TV app is checked on, and what they can decode. Player decisions (decoder fallback, audio
passthrough, ABIs) are verified on real hardware, not the emulator. How to connect: `docs/superpowers/specs/google-tv/F-build-test-release.md`
→ "Testing on the owner's TCL TV". Only the `scratch` build (`app.antenna.player.scratch`) is ever installed.

## Google TV emulator (`antenna-tv`)

- Image: `system-images;android-36;google-tv;arm64-v8a`, 1080p, 2 GB RAM (`android/scripts/emulator.sh`).
- Decodes in software: good for UI and flows, not for decoder or performance checks.

## Owner's TCL TV (Google TV)

Recorded 2026-11-16 over network debugging (`adb connect <tv-ip>:5555`; the owner accepted the prompt with "Always
allow"). The IP isn't kept here (it can change and the repo is public).

| | |
|---|---|
| Model | TCL Smart TV Pro (`G08`, product `G08_4K_GB`) |
| SoC | MediaTek MT5896 (`ro.board.platform` merak) |
| Android | 14 (API 34), Google TV launcher (`launcherx`), Assistant (`katniss`) |
| ABIs | **`armeabi-v7a`, `armeabi` only: a 32-bit userland.** The 32-bit builds of libmpv and the FFmpeg decoder are the ones this TV runs |
| RAM | 2.4 GB (`MemTotal 2451284 kB`), not flagged low-RAM |
| Display | 3840×2160 panel, UI at 1920×1080 (density 320) |
| Storage | 17 GB free of 21 GB |
| Features | `leanback`, `leanback_only`, `live_tv`, HDMI-CEC |

**Video decoders** (Codec2, hardware, from `/vendor/etc/media_codecs-mt5896.xml`): H.264, HEVC, VP9, AV1 up to
7680×4320; MPEG-2 up to 1920×1088; also VVC, VC-1, MPEG-4, H.263, VP8, AVS/AVS2/AVS3, WMV3, RealVideo, MJPEG and
Dolby Vision profiles; secure variants of the main ones. So ExoPlayer should play nearly every IPTV stream with
hardware decoding; mpv is the fallback for odd containers and broken streams, not for codecs.

**Audio decoders**: AC-3, E-AC-3 (incl. JOC/Atmos), DTS / DTS-HD / DTS:X P2, AAC (ADTS, LATM), MPEG L1/L2, WMA/WMA
Pro, ADPCM, Cook, plus Google's software decoders.

**Audio output** (built-in speaker device profiles): PCM 16-bit 48 kHz stereo, and encoded AC-3, E-AC-3, E-AC-3 JOC,
DTS, DTS-HD. Passthrough of surround formats is available even without a receiver.

**Skeleton check** (phase 1, `scratch` build): launches, drawer and Back behave as on the emulator, 27 MB PSS.
Uninstalled afterwards. The owner's TV had no Antenna/Tuner package installed.

### Benchmarks and player results (phases 3–4, `scratch` build)

Checked 2026-11-17 against the local test kit over Wi-Fi (`app.antenna.player.scratch`, R8 minified):

| Check | Result | Target |
|---|---|---|
| Cold start (`am start -W -S`) | **413 ms** (`TotalTime`, 427 ms `WaitTime`) | < 1.5 s |
| Memory while browsing (Home, Movies, Live TV) | **38 MB PSS** (139 MB RSS) | < 220 MB PSS |
| Memory while playing live MPEG-TS (720p H.264 + AAC) | **50 MB PSS** (163 MB RSS) | < 220 MB PSS |
| Memory while playing 4K HEVC + AC-3 (3840×2160 25 fps) | **60 MB PSS** (175 MB RSS) | < 220 MB PSS |
| Memory while playing 720p MP4 movie | **67 MB PSS** | < 220 MB PSS |
| Live TS first frame (`Tuner News`..`Tuner Kids`) | **~1.0 s**, zaps cleanly with D-pad Up/Down | < 2 s |
| Hardware H.264 + AAC | `c2.mtk.avc.decoder` + `c2.android.aac.decoder`, 25 fps, 0 dropped frames | Hardware |
| Hardware 4K HEVC (3840×2160 `hvc1`) | `c2.mtk.hevc.decoder`, 25 fps (`ROB: 25/s`), 0 dropped frames | Hardware |
| Hardware AC-3 audio (`audio/ac3`) | Direct offload to `audio_hw_primary` (`APAF Filter(Ac3)` hardware decode) | Passthrough / hardware |
| Dead channel (`Tuner Sports 4K`, HTTP 404) | Tries `.ts`, retries once as `.m3u8`, then shows the 404 card | Clean error |
| Episode playback, Up Next, and resume | Plays `Signal Lost`, shows Up Next above the scrubber, advances on OK, and updates `Resume` on Back | Matches Apple apps |
| Playlist share server (`Add a Playlist`) | Falls back to an available port when 8790 is busy, confirms on TV, and syncs catalog + posters | Matches spec |

### Navigation smoothness (2026-11-18, `scratch` build, the owner's own playlists)

A fixed D-pad run through Home (rows down and across), the sidebar, Live TV (categories, channels), Movies (grid,
a title page) and back, with `dumpsys gfxinfo` (`reset` before, stats after):

| | Before | After |
|---|---|---|
| Janky frames | 28.6% | **7.9%** |
| Median / p90 / p95 / p99 frame | 28 / 93 / 101 / 150 ms | **20 / 34 / 38 / 81 ms** |
| Slow UI thread / slow draw frames | 166 / 160 | **47 / 45** |
| Home rows only: janky, median | 97–100%, 81–89 ms | **8–11%, 26–27 ms** |

What mattered, in order: this GPU redraws the whole 1920×1080 screen every frame and each full-screen fill costs
roughly 10 ms, so the hero and title-page artwork with its fades renders once into a cached layer (`artworkLayer`),
and the window background and the pages hidden under the player are no longer drawn. Sideloaded installs get no Play
cloud profile, so `profileinstaller` and `baseline-prof.txt` compile the app ahead of time (before, it ran
interpreted/JIT: dexopt `status=verify`). Library reads map rows off the main thread. To compare builds fairly, force
the compile Android would otherwise run in the background:
`adb shell cmd package compile -m speed-profile -f app.antenna.player.scratch`.
