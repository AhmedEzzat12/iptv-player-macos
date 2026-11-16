# Shared test vectors

Language-neutral test cases that both the Swift `TunerCore` tests (`Tests/TunerCoreTests/VectorTests.swift`) and the
Android app's Kotlin tests (`android/core`, `VectorTest`) run, so the two ports give the same answers. Design:
`docs/superpowers/specs/google-tv/E-parity-tooling.md`.

## File format

```json
{
  "function": "StableID.slug",
  "shape": "string -> string",
  "generatedBy": "swift",
  "swiftCommit": "bc2b940",
  "cases": [ { "name": "…", "input": "…", "expected": "…" } ]
}
```

`function` picks the code under test (registered in `VectorTests.functions` and its Kotlin twin). `shape` says what
`input` and `expected` look like. Dates are ISO-8601 UTC strings. A case may add `"androidExpected"` for a deliberate
Android difference (also listed in `docs/android-parity.md`).

## Expected values come from Swift

Never write `expected` by hand:

1. Add cases with `"expected": null`.
2. `TUNER_VECTORS_REGENERATE=1 scripts/test.sh --filter VectorTests` fills them from the Swift code
   (`=all` recomputes every case: only when Swift's behaviour changed on purpose; say why in the commit).
3. Review the diff and commit. A plain `scripts/test.sh` fails on any null or mismatching case.

A Swift fix in one of these areas adds a case in the same commit; the Kotlin tests then fail until the fix is ported.

## Files

| File | Function | Shape |
|---|---|---|
| `stable-id/hash.json` | `StableID.hash` | string → string |
| `stable-id/sanitize.json` | `StableID.sanitize` | string → string |
| `stable-id/slug.json` | `StableID.slug` | string → string |
| `normalizer/channel-names.json` | `ChannelNameNormalizer.normalize` | string → string |
| `end-of-media/stall.json` | `EndOfMediaStall.hasEnded` | {position, duration, stalledFor} → bool |
| `catchup/m3u.json` | `CatchupURLBuilder.m3u` | {channelURL, type, template, tvgId, start, end, now} → string |
| `url-encoding/xtream.json` | `XtreamClient` URLs | {base, username, password, streamId, ext, start, minutes, serverTimeOffset} → {live, liveM3U8, movie, episode, timeshift, api} |

More areas (M3U/XMLTV parsing, category grouping, episode navigation, continue watching, skip segments, source
fingerprint) are added as they're ported (phase 2).
