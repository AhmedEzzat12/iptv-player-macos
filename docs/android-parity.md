# Android parity

How the Google TV app (`android/`) follows the Apple apps. Base: the commit in `android/PARITY_BASE`. Outstanding
work: `scripts/android-backlog.sh`. Mechanism: `docs/superpowers/specs/google-tv/E-parity-tooling.md`.

## Ported areas

| Area | Swift file(s) | Kotlin file(s) | Ported from | Notes |
|---|---|---|---|---|

(Filled in from phase 2 on, one row per ported area.)

## Deliberate differences

- **Xtream live format.** Android requests `.ts` first and falls back to `.m3u8`; Apple requests HLS for AVFoundation
  and TS for mpv. ExoPlayer plays raw TS well and starts faster.
- **Quick reopen default.** A closed movie or episode stays ready for 2 minutes by default on TV (Apple: 10). TV boxes
  have little RAM. The setting offers the same choices.
- **Lenient JSON `int` on "nan"/"inf".** Swift's `JSONObject.int` traps (crashes) converting a non-finite double to
  `Int`; Kotlin returns null. Those inputs are left out of `Tests/Vectors/lenient-json/accessors.json`. The Swift crash
  is a bug worth fixing in the Apple apps (reported 2026-11-16).
