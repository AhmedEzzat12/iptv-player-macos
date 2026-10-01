# iPhone / iPad port: handover

Date: 2026-10-01. **Status: paused at Ahmed's request.** No iOS code has been written and nothing in the repo was changed for
iOS. This file is the starting point for whoever resumes. The detailed research is in
[`ios-port-research.md`](ios-port-research.md), which was written before the distribution decision below. Read this file first:
it records the decision, what was verified on this Mac, and which parts of the research it makes obsolete.

## 1. Decisions so far

| Decision | Status | Source |
|---|---|---|
| **Personal use only**: never the public App Store | **Decided** (Ahmed, 2026-10-01) | Answer to research §10 Q1 |
| Minimum OS iOS/iPadOS 18 (tvOS 18 later) | Proposed, not confirmed | Research §10 Q4 |
| Keep AVFoundation as the first engine and add an mpv fallback on iOS | Recommended, not started | Research §2 |
| SPM libraries plus a thin `Tuner.xcodeproj` for the iOS app target | Recommended, not started | Research §1.1 |

## 2. What "personal use only" changes

A revision pass over the research was started for this and then stopped, so these points are a **preliminary assessment and not
re-verified with sources**. Confirm them before relying on them.

- **App Store review risk (research §7) and Phase 5 "App Store readiness" no longer apply.** No demo server, review notes, age
  rating or privacy policy are needed.
- **GPL builds become acceptable.** GPL obligations are triggered by distributing the software; building it for your own devices
  isn't distribution. That re-opens **MPVKit's GPL build** (more codecs and demuxers) alongside the LGPL one that research §2
  recommended. Pick whichever MPVKit product plays the most of Ahmed's library; the rendering plan (GLES render API →
  `CVPixelBuffer` → `AVSampleBufferDisplayLayer`, for system PiP) is unchanged.
- **KSPlayer stays out.** The last finding before the pass was stopped: its free GPL tier is deliberately limited (FFmpeg 6.1, not
  all demuxers and decoders, no live-stream rewind).
- **TMDB:** its commercial agreement only applies to monetised apps, so a personal key is fine. Cinemeta's terms don't matter for
  private use.
- **DVR:** no longer a review issue, but iOS still can't record while the app is suspended. For a personal setup, the attractive
  option is **the Mac app as the DVR and AirPlay hub, with iPhone/iPad scheduling and playing back** (research §9 "Later").
- **Signing/installing on own devices:** researched with sources (2026-10-01). Details are in §2a.
  - **Open:** is Ahmed enrolled, or willing to be? (research §10 Q9)

### 2a. Installing on your own iPhone, iPad and Apple TV

Sources were checked 2026-10-01. Items marked UNVERIFIED weren't confirmed from Apple or official project pages.

**Free Apple ID (Personal Team)** ([Apple](https://developer.apple.com/help/account/basics/about-your-developer-account)):
- Limits: 3 devices, 3 apps per device, 10 App IDs. Everything expires after **7 days**, so you rebuild and reinstall weekly.
- No TestFlight and no ad hoc distribution.

**Paid program ($99/year):**
- 100 devices per product family.
- Development profiles last about a year, capped by the membership (UNVERIFIED, based on forum posts).
- Allows TestFlight "Internal Only" builds: no Beta App Review, builds expire after 90 days, and Apple TV is supported on tvOS 18+.

**Capabilities Tuner needs:**

| Capability | Free | Paid | Notes |
|---|---|---|---|
| Background audio + PiP + AirPlay | ✓ | ✓ | No entitlement needed: Background Modes `audio` and an `AVAudioSession` |
| Local network (AirPlay bridge) | ✓ | ✓ | Just `NSLocalNetworkUsageDescription` in Info.plist |
| App Groups, Keychain Sharing | ✓ | ✓ | |
| iCloud (CloudKit / key-value) | ✗ | ✓ | Needed to sync settings or favourites between devices |
| Push / Time Sensitive notifications | ✗ | ✓ | Local reminder notifications don't need push |

**Other facts:**
- **Developer Mode:** must be turned on on iPhone/iPad (Settings → Privacy & Security). tvOS has none.
- **Pairing:** Xcode 27 replaces the Devices window with **Device Hub**. Wireless pairing needs iOS 27; pair Apple TV via Settings →
  Remotes and Devices.
- **Re-signing tools:**
  - AltStore Classic 2.3 and SideStore 0.7.0-alpha automate the free-account re-signing but keep the same 3-app/10-App-ID limits.
    Avoid SideStore 0.6.4.
  - A Mac `launchd` job running `xcodebuild -allowProvisioningUpdates` and then `xcrun devicectl device install app` every 5–6
    days also works.

**Recommendation:** use the **paid program with Xcode development signing**. You install directly from Xcode or `devicectl`, nothing
is uploaded to Apple, it works for about a year at a time, iCloud sync works, and iPhone, iPad and Apple TV are all covered. The free
path works only if you drop iCloud and accept a weekly rebuild. Your 3 devices would use up its whole device limit.

## 3. Verified on this Mac (2026-10-01)

| Item | Finding |
|---|---|
| Xcode | `/Applications/Xcode.app`, **Xcode 27.0 (27A266a)**, with the iOS 27 and tvOS 27 SDKs |
| Using Xcode without switching | Works: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …` runs without `sudo xcode-select`, so the macOS build (Command Line Tools, `scripts/build-app.sh`) is unaffected |
| Xcode licence | **Accepted.** `IDEXcodeVersionForAgreedToGMLicense = 27.0` and `xcodebuild` runs. Research §0 says "not accepted"; that is now out of date. |
| iOS Simulator runtime | Not installed when checked. **Ahmed was downloading it at handover time.** Verify with `xcrun simctl list runtimes`. |
| `TunerCore` for iOS, as the repo is today | `xcodebuild -scheme TunerCore -destination 'generic/platform=iOS'` **fails**, mostly with availability errors because `Package.swift` declares only macOS: `Task.sleep(for:)`, `Locale.Region`, `Locale.LanguageCode` and `isoRegions` need iOS 16+ (`HTTPClient.swift`, `TitleMatcher.swift`, `OnlineGuideCatalog.swift`). |
| `TunerCore` with `.iOS(.v18)` added (tested in a scratch copy only) | The **only** remaining errors are `Process` in `Sources/TunerCore/Services/RecordingService.swift` (lines 7, 107, 117). GRDB 7 and the `CZlib` target compile for iOS as they are. This confirms research §1.2. |

## 4. First steps when work resumes

1. **Ahmed:** finish the simulator download (`xcodebuild -downloadPlatform iOS`) and decide on the Apple Developer Program.
2. `Package.swift`: change `platforms` to `[.macOS(.v15), .iOS(.v18)]`.
3. `RecordingService`: wrap the ffmpeg `Process` code (`processes`, `start`, `stop`, `finished`) in `#if os(macOS)`. On iOS,
   `start` should throw a "recording isn't available on this device" error. Keep the scheduling and `tick()` logic shared.
4. Check that the core builds: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme TunerCore -destination 'generic/platform=iOS' build`.
   Then run the tests on the simulator (`xcodebuild test -scheme TunerCore -destination 'platform=iOS Simulator,name=…'`).
   Note: `scripts/test.sh` hard-codes the Command Line Tools Swift Testing plugin path, so use `xcodebuild` for iOS.
5. Make sure the macOS app is unaffected: `scripts/build-app.sh release` and `./scripts/test.sh` (89 tests) must still pass.
6. Then follow research §1.1 and §9:
   - split the app target into `TunerPlayback` and `TunerUI`, with a `PlatformView` shim;
   - create `Tuner.xcodeproj` with the iOS target;
   - Phase 1 is the AVFoundation-only MVP.
   Skip Phase 5.

## 5. macOS lessons that carry over to iOS (don't re-learn them)

- **HEVC in MPEG-TS HLS:** AVFoundation plays the audio and silently drops the video, with no error. Many of Ahmed's sports and
  4K channels are like this. The detection in `AVEngine` (`videoMissing` → `EngineEvent.videoUnsupported`) and the fallback in
  `PlayerSlot.videoUnsupported()` must come along to iOS, otherwise those channels show a black screen there too. Until the mpv
  fallback lands on iOS (Phase 2), those channels will show the "No picture for this stream" notice.
- **AirPlay bridge:** on macOS it runs ffmpeg `-c copy` as a separate process (with a watchdog). iOS can't launch processes, so it
  needs the in-process remuxer (research §3). HEVC needs fMP4 segments, the `hvc1` tag and `-bsf:a aac_adtstoasc` (or the
  libavformat equivalent); without that filter the muxer fails with a misleading EPERM.
- **ATS:** keep only `NSAllowsArbitraryLoads`. Adding `NSAllowsLocalNetworking` (or the media key) makes the system ignore it and
  blocks plain-HTTP IPTV servers. On iOS, add `NSLocalNetworkUsageDescription` for the AirPlay bridge.
- **Undocumented asset option:** `AVEngine` passes `"AVURLAssetHTTPHeaderFieldsKey"`, which isn't public API. That's harmless for
  personal use, but it may change between OS versions.
- **Ahmed's provider:**
  - one simultaneous connection: always stop the old stream before opening a new one;
  - about 12k channels, 41k movies (about 45% MKV, so they need mpv) and 15k series;
  - no EPG;
  - it sometimes returns malformed JSON (handled by lenient parsing and retries in `HTTPClient`);
  - some episodes return HTTP 503 from the provider (not an app bug).
- **Real-data testing:** the metadata matcher crashed on Ahmed's library (an `Int.max + 1` overflow for still-running series),
  although every test and fixture passed. Test new builds against a copy of the real library before shipping. On iOS that's a copy
  of `tuner.sqlite`.
- **Credentials:** Ahmed's Xtream login is never stored in the repo, docs or memory. He enters it in the app himself.

## 6. Open questions for Ahmed

1. Apple Developer Program membership: paid ($99/year: 1-year installs, TestFlight) or free Apple ID (re-install about every 7 days)?
2. Is iOS/iPadOS 18 acceptable as the minimum?
3. DVR on iPhone: is it needed at all, or is "the Mac records, iPhone/iPad play back" enough?
4. Is tvOS in scope, and should it come before the iPad polish (multiview, keyboard, menu bar)?
5. Should the Mac app eventually switch from Homebrew libmpv/ffmpeg to bundled MPVKit, so there's one engine everywhere and no
   Homebrew dependency?

## 7. Files

| File | What it is |
|---|---|
| `docs/ios-handover.md` | This summary |
| `docs/ios-port-research.md` | Full research: architecture, engine comparison, per-module port table, iPad UX, tvOS, licensing, phased plan. §7 and Phase 5 are obsolete for personal use; §0's licence status is out of date. |
| `docs/design.md` | macOS architecture and decisions, including engine routing and fallback and the AirPlay bridge |
| `README.md`, `docs/testing.md` | macOS build and test instructions, and the local test kit |
