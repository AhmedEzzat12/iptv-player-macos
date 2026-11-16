# Android test devices

Devices the Google TV app is checked on, and what they can decode. Player decisions (decoder fallback, audio
passthrough, ABIs) are verified on real hardware, not the emulator. How to connect: `docs/superpowers/specs/google-tv/F-build-test-release.md`
→ "Testing on the owner's TCL TV". Only the `scratch` build (`app.antenna.player.scratch`) is ever installed.

## Google TV emulator (`antenna-tv`)

- Image: `system-images;android-36;google-tv;arm64-v8a`, 1080p, 2 GB RAM (`android/scripts/emulator.sh`).
- Decodes in software: good for UI and flows, not for decoder or performance checks.

## Owner's TCL TV (Google TV)

Not recorded yet: needs the TV on the network with Developer options → network debugging enabled.
To fill in: model, Android version, `getprop ro.product.cpu.abilist`, RAM (`/proc/meminfo`), video decoders
(`dumpsys media.player` / `MediaCodecList`: H.264, HEVC, VP9, AV1, max resolution), audio decoders and passthrough
(AC-3, E-AC-3, DTS), and phase 3/4 benchmark results.
