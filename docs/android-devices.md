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

Benchmarks (phase 3) and player results (phase 4) go below.
