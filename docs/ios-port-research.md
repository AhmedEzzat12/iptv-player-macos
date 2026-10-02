# Tuner on iPhone, iPad (and Apple TV): port research

Date: 2026-10-01. Status: research only. No source files were changed, no builds were run and the app was not launched.
Current releases: iOS/iPadOS 27.0.1, tvOS 27.0, Xcode 27. App Store uploads have needed Xcode 26+ / 26 SDKs since 2026-04-28
([Apple releases](https://developer.apple.com/news/releases/), [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)).
Sources are linked inline. Anything not confirmed from a primary source is marked **UNVERIFIED**.

---

## TL;DR recommendation

**What to build**
- Keep `TunerCore` exactly as it is. It is about 6.8k lines and already UI-free.
- Turn the SwiftUI app into a shared library, and add a small Xcode project with an iPhone/iPad app target.
- Build a new player-presentation layer for touch: tabs, full-screen player, gestures.

**Playback:** keep AVFoundation as the first engine, as on macOS. For the fallback on iOS:
- Replace the dlopen'ed Homebrew libmpv with **MPVKit's LGPL build (version 1.0.0 or later)**.
- Render through mpv's **OpenGL ES render API into pixel buffers shown by an `AVSampleBufferDisplayLayer`**. This is the only mpv route that also gives system Picture in Picture.
- Without the fallback, about 45% of your own provider's 41k movies (MKV) would not play.
- Later, replace the external `ffmpeg` process (recording and the AirPlay bridge) with a small in-process libavformat remuxer. It would use the same FFmpeg that MPVKit already bundles.

**Defer on iOS:**
- **Scheduled DVR:** iOS cannot run recordings while the app is suspended.
- **tvOS UI:** the core and engines carry over, but focus-driven UI is a separate project.

**Before any code:** decide whether this goes to the **public App Store** or stays personal. That one answer changes the licensing work, the review risk and the feature set (see [Open questions](#10-open-questions-for-the-owner)).

**Rough effort:** one developer, with uncertainty of about ±50%.
- iPhone/iPad with AVFoundation only: about 3–4 weeks.
- The mpv fallback with PiP: another 2–3 weeks.
- The remux/AirPlay bridge: another 2 weeks.
- App Store readiness: another week.

---

## 0. Starting point (checked on this Mac)

| Item | Finding |
|---|---|
| Active developer dir | `xcode-select -p` → `/Library/Developer/CommandLineTools` (Command Line Tools only) |
| Xcode | `/Applications/Xcode.app` **is installed: Xcode 27.0 (27A266a)**. `iPhoneOS27.0.sdk` and `AppleTVOS27.0.sdk` are present. |
| License | **Not accepted.** `xcodebuild` refuses to run until `sudo xcodebuild -license` is done. |
| Simulator runtimes | **None installed.** `/Library/Developer/CoreSimulator/Images/images.plist` is empty, and `simctl` can't run until the license is accepted. Old device records for iOS 16 runtimes exist but point at runtimes that aren't installed. |
| Toolchain / OS | Swift 6.4, macOS 27.0.1. Xcode 27 needs macOS 26.6+ ([Xcode support](https://developer.apple.com/support/xcode/)). |
| Dependency platform floors | GRDB 7.11.1 supports iOS 13+ and tvOS 13+ (from its `Package.swift`). MPVKit supports iOS/tvOS 15+. |

**Setup steps for you to run.** I did not run any of them. The license is a legal agreement you accept yourself.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # switch from CLT to Xcode
sudo xcodebuild -license                                          # read + accept
xcodebuild -runFirstLaunch
xcodebuild -downloadPlatform iOS                                  # simulator runtime (tvOS later: -downloadPlatform tvOS)
xcrun simctl list runtimes                                        # verify
```

- The download step is documented in [Downloading additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).
- Running on a physical device for longer than 7-day free provisioning, and TestFlight/App Store, need a paid Apple Developer Program membership.
- After switching to Xcode, the Command Line Tools workarounds become optional: the `@ViewState` alias and the Swift Testing `-plugin-path` in `scripts/test.sh`. Re-check `scripts/test.sh`, since its hard-coded plugin path may differ under Xcode.
- The Command Line Tools ship only the macOS SDK ([TN2339](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)). iOS work requires Xcode.

---

## 1. Recommended architecture

### 1.1 Project structure

| Option | Verdict |
|---|---|
| SwiftPM only (today's setup) | **Not possible for iOS.** `swift build` can't produce a signed `.app` with an Info.plist, entitlements, asset catalog and provisioning. Xcode Cloud also can't build standalone packages; Apple's pattern is a local package inside an app project ([Xcode Cloud doc](https://developer.apple.com/documentation/xcode/building-swift-packages-or-swift-playground-app-projects-with-xcode-cloud)). |
| Move everything into one multiplatform Xcode project | Works, but you lose `swift test` on macOS and get a large `.pbxproj` to diff-review. |
| **SPM libraries + thin Xcode app targets (recommended)** | `Package.swift` stays the source of truth for code and tests. A small `Tuner.xcodeproj` (Xcode 16+ folder-synchronised groups keep it small) holds the iOS app target and, later, tvOS. The macOS app can stay on `scripts/build-app.sh` until you choose to move it. XcodeGen/Tuist are optional third-party tools and not needed. |

Proposed package layout. This is a refactor of the current `Tuner` executable target, not a rewrite.

```
Package.swift   platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)]
  CZlib            unchanged (zlib ships in every Apple SDK)
  TunerCore        unchanged + small #if os() fixes (Swift 6)
  CMPV             macOS only — the dlopen shim (dependency condition: .when(platforms: [.macOS]))
  TunerPlayback    PlaybackEngine, AVEngine, MPVEngine (+ platform renderers), PlayerSlot, PlayerManager,
                   remuxer/AirPlay bridge, NowPlaying  (Swift 5 mode, like today)
                   iOS/tvOS dependency: MPVKit (LGPL product), condition .when(platforms: [.iOS, .tvOS])
  TunerUI          AppModel, Preferences, shared SwiftUI views (+ per-platform view files)
  Tuner (exe)      macOS App struct only (today's TunerApp/AppDelegate/commands)
Tuner.xcodeproj
  Tuner-iOS        App struct, Info.plist, entitlements, assets → depends on TunerUI
  Tuner-tvOS       (later)
```

- **Don't link CMPV and MPVKit into the same binary.** The shim defines every `mpv_*` symbol, so the two would clash.
- **Don't link two FFmpeg builds** (for example MPVKit plus KSPlayer's FFmpegKit). They clash too.

A thin platform shim removes most of the `#if` noise:

```swift
#if os(macOS)
typealias PlatformView = NSView;  typealias PlatformImage = NSImage
#else
typealias PlatformView = UIView;  typealias PlatformImage = UIImage
#endif
// + a ~20-line `PlatformViewRepresentable` protocol that maps makeNSView/makeUIView to one make()/update().
```

### 1.2 What compiles as-is: grounded in the code

- `TunerCore` imports only `Foundation`, `GRDB`, `CryptoKit`, `os` and `CZlib`. All of these exist on iOS and tvOS.
- **The only hard compile blocker** is `RecordingService`. It uses `Foundation.Process`, and `NSTask.h` declares it `API_UNAVAILABLE(ios, watchos, tvos)`.
- Smaller adaptations:
  - Default paths (`.moviesDirectory` exists on iOS but lands in the app container).
  - Credentials stored in SQLite.
  - Database location and backup policy (see §4.9).

27 of the app's 48 Swift files import AppKit. What they use:

| AppKit dependency | Where | iOS/iPadOS replacement |
|---|---|---|
| `NSViewRepresentable` video hosting (`VideoContainerView`, `AVPlayerHostView`, `MPVVideoView`) | SlotVideoView, AVEngine, MPVEngine | `UIViewRepresentable`; a `UIView` subclass with `layerClass = AVPlayerLayer`. Corners and shadow stay as Core Animation properties. The macOS workarounds for "AppKit view composited above SwiftUI decorations" may not be needed in UIKit. **Re-verify; don't assume.** |
| Window-coordinate frame probe (`PlayerPreviewFrameReporter`: NSView + `CADisplayLink`) | Components.swift | Same idea with a `UIView` and `CADisplayLink`. On iOS, split-view columns and tabs are also separate hosting controllers, so the window-level `PlayerHost` overlay still makes sense. |
| `NSEvent` local monitors (keyDown, mouseMoved, scrollWheel), `NSCursor`, window buttons, `NSMenu` tracking, full-screen notifications | KeyboardShortcuts, PlayerHost | Touch gestures for the chrome. `.keyboardShortcut`, `.onKeyPress` (iOS 17+) and the iPadOS 26 menu bar for keys. `scenePhase` instead of window notifications. |
| `@NSApplicationDelegateAdaptor`, `Settings {}` scene, `.windowToolbarStyle`, `.toolbar(…, for: .windowToolbar)` | TunerApp, RootView | `@UIApplicationDelegateAdaptor` (audio session and background-task registration). Settings becomes a tab or sheet. The toolbar modifiers go away. |
| `.commands { TunerCommands }` | KeyboardShortcuts | Reuse almost unchanged. On iPadOS 26, SwiftUI commands build the iPad menu bar ([WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/)). |
| `NSOpenPanel` ×3, `NSSavePanel` ×1 | Source editor, Welcome, Settings | `.fileImporter` / `.fileExporter` |
| `NSPasteboard` ×6, `NSWorkspace.open` ×7, `activateFileViewerSelecting`, `icon(forFile:)` | Settings, VOD, Recordings | `UIPasteboard`, `@Environment(\.openURL)`, `ShareLink` / Files app |
| `AVRoutePickerView.player` | AirPlayButton | The `player` property is **macOS-only** (per the SDK header). On iOS, wrap `AVRoutePickerView` in `UIViewRepresentable` without it. AVPlayer's `allowsExternalPlayback` (default true) routes the video ([doc](https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback)). |
| `NSImage` artwork | NowPlaying, VODCards | `UIImage` / `Image` |
| CGL + `CAOpenGLLayer` | MPVVideoLayer | GLES render API to CVPixelBuffer to `AVSampleBufferDisplayLayer` (see §2) |
| SwiftUI APIs that don't exist on iOS | `toggleStyle(.checkbox)` ×1, `buttonStyle(.link)` ×1, `menuStyle(.borderlessButton)` ×4, `onExitCommand` ×1 (macOS/tvOS only) | Swap for iOS styles. `.help()` ×84, `.onHover` ×15, `.onContinuousHover` and `.onKeyPress` ×9 all compile on iOS. |
| Missing entirely on macOS today | — | `AVAudioSession` (`.playback`) is required on iOS for background audio, PiP and AirPlay (§4.2). |

---

## 2. Playback engine decision (the libmpv question)

### 2.1 What Tuner needs from an engine (from the macOS code and your account)

- HLS and MP4, handled by AVFoundation.
- Raw MPEG-TS over HTTP (M3U panels).
- **MKV VOD:** 45% of your provider's movies.
- HEVC inside MPEG-TS HLS segments. Apple's HLS spec requires fMP4 for HEVC: "The container format for HEVC video MUST be fMP4" ([HLS authoring spec](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices)).
- AC-3, E-AC-3 and DTS audio.
- Selectable audio and subtitle tracks.
- Up to 4 simultaneous slots.
- PiP, AirPlay and Now Playing.

### 2.2 Options compared

| Option | License | Maintenance (as of 2026-10-01) | Renderer on iOS | HW decode | PiP for non-AVPlayer content | Size | App Store | Verdict |
|---|---|---|---|---|---|---|---|---|
| **AVFoundation only** | Apple | — | AVPlayerLayer | native | native | 0 | ✅ | Breaks MKV, raw TS, HEVC-in-TS and DTS. **Not enough on its own.** |
| **[MPVKit](https://github.com/mpvkit/MPVKit) (LGPL product)** | LGPLv3 (mpv `-Dgpl=false`, FFmpeg `--enable-version3`) | 1.0.0 released 2026-07-25 (mpv 0.41.0, FFmpeg n8.1.2, MoltenVK 1.4.2); 28 commits in 2026. README says it is "only suitable for learning libmpv" | (a) libmpv **render API on OpenGL ES**; (b) `vo=gpu-next` on MoltenVK via an MPVKit-only patch (upstream PR [#7857](https://github.com/mpv-player/mpv/pull/7857) closed unmerged) | VideoToolbox | Do it yourself: GLES → IOSurface CVPixelBuffer → `AVSampleBufferDisplayLayer` | ≈110 MB of zipped xcframeworks (all slices). The shipping app [AerioTV](https://apps.apple.com/us/app/aeriotv/id6760727974) is 45.8 MB in total | ✅ precedent: AerioTV (IPTV app for iOS, iPadOS and tvOS, uses plain MPVKit 1.0.0 per its [licences file](https://github.com/jonzey231/AerioTV/blob/main/THIRD_PARTY_LICENSES.md)) | **Recommended** |
| MPVKit-GPL | GPLv3 (adds libsmbclient) | same | same | same | same | ≈same | ❌ GPL vs App Store terms ([FSF 2010](https://www.fsf.org/news/2010-05-app-store-compliance); VLC pulled in 2011) | No |
| Self-built libmpv | LGPL if built with `-Dgpl=false` | mpv 0.41.0 (2025-12-21). Upstream has no iOS Vulkan context; the render API exposes only OpenGL and SW ([render.h](https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h)) | GLES or patched MoltenVK | VideoToolbox | do it yourself | ? | ✅ if LGPL | No: MPVKit already does this work |
| VLCKit 3 (MobileVLCKit/TVVLCKit) | LGPLv2.1+ | 3.7.4, 2026-09-30. **CocoaPods only, and CocoaPods trunk goes read-only 2026-12-02** ([blog](https://blog.cocoapods.org/CocoaPods-Specs-Repo/)) | GLES | VideoToolbox | **none** | 233 MB download | ✅ (VLC for iOS) | No: no PiP, and a dying distribution channel |
| VLCKit 4 | LGPLv2.1+ | **alpha** (4.0.0a25, 2026-09-30); SPM binary target | `AVSampleBufferDisplayLayer` | VideoToolbox | **built in** (`VLCPictureInPictureDrawable`) | 923 MB zip (all platforms) | ✅ once stable | **Plan B.** Cleanest licence (v2.1, dynamic frameworks) and PiP, but it is alpha and a different API from mpv |
| [KSPlayer](https://github.com/kingslay/KSPlayer) | GPL-3.0; LGPL only through a paid licence (3–15% of revenue, at least $15/month, 6 months upfront; [issue #731](https://github.com/kingslay/KSPlayer/issues/731)) | last tag 2.3.4 (Feb 2025); main is active | Metal / AVSBDL | VideoToolbox | built in | ~80 MB app | ✅ only with the paid LGPL licence (APTV and UHF use it) | Possible if you'll pay; it brings its own FFmpeg |
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | LGPL-3.0 + App Store exception | created 2026-04, single maintainer | FFmpeg demux → loopback → AVPlayer for H.264/HEVC/AV1; AVSBDL otherwise | native | native or sample-buffer | ? | ? | Interesting design (same idea as §3's remux tier), too young to depend on |

### 2.3 Decision

#### Tier 1: AVFoundation (unchanged)

`AVEngine` ports with small changes:
- A `UIView` host.
- An audio session.
- `canStartPictureInPictureAutomaticallyFromInline` ([doc](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline)).
- Detaching `playerLayer.player` when the app backgrounds without PiP, so audio keeps playing ([Apple guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/RefiningTheUserExperience/RefiningTheUserExperience.html)).

All of the error mapping, `videoUnsupported` detection and routing in `PlayerSlot` carries over.

#### Tier 2: MPVKit (LGPL, ≥ 1.0.0), using the OpenGL ES render API into pixel buffers

**Why the render API and not gpu-next/MoltenVK:**
- It is the same libmpv API that `MPVRenderer` uses on macOS today: update callback, render queue, `mpv_render_context_render`. Most of `MPVEngine` carries over: options, the event pump, the track list and snapshots. Only `MPVVideoLayer` (CGL) is rewritten.
- It is the only mpv path that can feed `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` (iOS/tvOS 15+, [doc](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)).
- The MoltenVK path renders into a `CAMetalLayer`, which PiP can't use.
- mpv has no native AVSampleBufferDisplayLayer output ([mpv#8910](https://github.com/mpv-player/mpv/issues/8910), open since 2021).

**How it works:**
- Render each frame into a ring of IOSurface-backed `CVPixelBuffer` FBOs (via `CVOpenGLESTextureCache`).
- Wrap each one in a `CMSampleBuffer` and enqueue it on an `AVSampleBufferDisplayLayer`.
- AerioTV documents this pattern in production, including `hwdec=videotoolbox-copy` for UHD HEVC, backpressure on `isReadyForMoreMediaData` and a stall watchdog ([changelog](https://github.com/jonzey231/AerioTV/blob/main/CHANGELOG.md)).
- Also set `ao=audiounit` and route mpv's audio through the shared `AVAudioSession`.

**Risk:** OpenGL ES has been deprecated since iOS 12 ([doc](https://developer.apple.com/documentation/opengles)). It still works in shipping apps in 2026, and Apple has announced no removal date. **UNVERIFIED** whether a future iOS will remove it.
- Mitigation: keep the renderer behind its own small protocol, so you can swap in VLCKit 4 (which already renders to `AVSampleBufferDisplayLayer`) if GLES goes away. Keep the remux tier (§3) as well.

#### Tier 3 (later): in-process remux to AVPlayer

- Use libavformat (the same FFmpeg that MPVKit links) to copy MKV/TS/HEVC-in-TS into HLS with fMP4 segments (`hvc1`-tagged).
- Serve it from the existing `HLSFileServer` (NWListener) and play it in AVPlayer.
- This gives the native engine's PiP, **AirPlay video**, HDR and lower power use for H.264/HEVC content. It also replaces the macOS `ffmpeg` process (§3).
- Use it for VOD and AirPlay, not for live zapping: segmenting adds several seconds of latency, so mpv stays better for fast live channel changes.

#### Multiview on iOS

- Apple documents no limit on simultaneous AVPlayers. In practice the hardware decoders run out and AVPlayer fails with `AVError.decoderTemporarilyUnavailable` (-11839) ([doc](https://developer.apple.com/documentation/avfoundation/averror-swift.struct/decodertemporarilyunavailable), [forum](https://developer.apple.com/forums/thread/67382)).
- Each mpv instance on iOS also costs a GLES context plus a decoder.
- Plan:
  - iPad: allow 2×2 and main + 3, with `preferredMaximumResolution` on the non-main cells.
  - iPhone: cap at main + one inset.
  - Test on the oldest supported iPad.
- Your provider allows only one connection anyway.

---

## 3. Replacing the external `ffmpeg` process (recording and AirPlay bridge)

### FFmpegKit status (verified)

- arthenica/ffmpeg-kit was **retired on 2025-01-06**. Its prebuilt binaries were removed through 2025-02-01 / 2025-04-01, and the repo was **archived on 2026-07-02** ([repo](https://github.com/arthenica/ffmpeg-kit)).
- The official successor, [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) (v9.0.0, 2026-08-23), is **source-only**: you build it with Nix, and it publishes no SPM, CocoaPods or Maven packages. It is LGPL-3.0, or GPL-3.0 if GPL libraries are enabled.
- Other options:
  - [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit): GPL-3.0 unless you buy a licence.
  - Small SPM wrappers: [jaywcjlove/ffmpeg-kit](https://github.com/jaywcjlove/ffmpeg-kit), [kewlbear/FFmpeg-iOS](https://swiftpackageregistry.com/kewlbear/FFmpeg-iOS) (stale).

**Recommendation:** don't wrap the ffmpeg command line. Write a small `Remuxer` (C or Swift) against **MPVKit's own `Libavformat`/`Libavcodec` products**, so there is one FFmpeg in the app.
- The core loop is FFmpeg's [remux example](https://ffmpeg.org/doxygen/trunk/remux_8c-example.html): `avformat_open_input` → `av_read_frame` → `av_interleaved_write_frame`, with the codec parameters copied.
- Outputs:
  - HLS with `hls_segment_type=fmp4` for the bridge.
  - MPEG-TS for recordings ([muxer docs](https://ffmpeg.org/ffmpeg-formats.html)).
- Audio AirPlay devices can't decode (DTS) can be re-encoded to AAC with FFmpeg's native AAC encoder, which is LGPL.
- The same `Remuxer` can replace `Process(ffmpeg)` on macOS as well. That drops the `brew install ffmpeg` requirement, but FFmpeg would then ship inside the Mac app and its licence obligations apply there too.

### AirPlay on iOS

| Approach | AirPlay video? | Evidence |
|---|---|---|
| AVPlayer playing the provider's URL directly | ✅ The Apple TV fetches the URL itself | Native. **Caveat:** custom HTTP headers are not forwarded to the receiver ([Apple engineer](https://developer.apple.com/forums/thread/705408)). Tuner's per-channel `#EXTVLCOPT` user-agent/referrer streams can fail on an Apple TV even when they play on the phone, and the bridge fixes that. |
| Local HTTP bridge (libavformat → HLS fMP4 → `NWListener`) | ✅ **only if the URL uses the phone's LAN IP**, not 127.0.0.1 | The receiver pulls the segments itself ([forum 51613](https://developer.apple.com/forums/thread/51613)). That this works with a phone-hosted server is from forum reports, not Apple documentation: **UNVERIFIED** until tested. The bridge's existing `lanAddress()` (getifaddrs) already does this. |
| `AVAssetResourceLoaderDelegate` serving segments | ❌ | Segments must be HTTP redirects ([forum 113063](https://developer.apple.com/forums/thread/113063)); "Video AirPlay is not supported" with a custom loader ([forum 28101](https://developer.apple.com/forums/thread/28101)) |
| `AVSampleBufferDisplayLayer` engines (mpv/VLC/KSPlayer) | ❌ video (audio only) | [WWDC17 509](https://nonstrict.eu/wwdcindex/wwdc2017/509/); [Supporting AirPlay](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app). The user's only option is screen mirroring. |

- Accepting incoming TCP connections does **not** trigger the local-network permission prompt. Outgoing LAN connections and Bonjour do ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
- The app must stay alive while the Apple TV pulls segments. While AirPlay is active it is legitimately "playing", so the audio background mode covers it. **Test it**: GCDWebServer, for example, suspends itself when the app is backgrounded.

### Recording on iOS: what's feasible

| Scenario | Feasible? | Why |
|---|---|---|
| Record while Tuner is in the foreground | ✅ | In-process remux |
| Record in the background while Tuner is audibly playing that channel | ✅ (defensible) | The `audio` background mode is for audible content ([doc](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)); guideline 2.5.4 |
| "Record until the programme ends", started by the user | ⚠️ maybe | iOS 26 `BGContinuedProcessingTask` must be user-initiated from the foreground, shows progress and can be expired under load ([doc](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), [WWDC25 227](https://developer.apple.com/videos/play/wwdc2025/227/)). **Untested, and App Review acceptance is UNVERIFIED.** |
| **Scheduled recordings while the app is suspended** | ❌ | `BGProcessingTask` runs only when the device is idle, at times the system chooses; `BGAppRefreshTask` gets about 30 s ([doc](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)). Background `URLSession` is for finite files, and `AVAssetDownloadTask` can't save live HLS ([doc](https://developer.apple.com/documentation/avfoundation/using-avfoundation-to-play-and-persist-http-live-streams)). |
| Download VOD for offline use | ✅ technically | Background `URLSession` for MP4/MKV files. Same 5.2.3 review risk as DVR. |

**Conclusion:** the realistic options for scheduled DVR on iPhone are:
- Server-side: the **Mac app as the DVR host** (it already has the scheduler and ffmpeg) with iOS as a client, or a Channels DVR-style backend.
- Leaving DVR off iOS v1, which also removes the biggest 5.2.3 risk (§7).

---

## 4. Per-module port table

**Verdicts:**
- **Reuse**: compiles as-is or with trivial edits.
- **Adapt**: same design with platform-specific parts.
- **Rewrite**: new implementation.

**Effort:** S is under 2 days, M is 2–5 days, L is 1–2 weeks.

| Module (LOC) | Verdict | Notes | Effort |
|---|---|---|---|
| TunerCore/Models (568), Parsing (1095), Networking (255), Providers (804), Metadata (1524) | **Reuse** | Pure Foundation. XMLTV uses `.alwaysMapped`, which is fine on iOS (mapped pages are evictable). Watch peak memory on very large guides on iPhone. | S |
| TunerCore/Database (1413) | **Adapt** | Works as-is. Split it into a rebuildable **library/EPG** DB (excluded from backup, `isExcludedFromBackup`, [doc](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)) and a backed-up **user** DB (sources, favourites, progress, groups), so iCloud backups don't carry millions of programme rows. tvOS requires this split anyway (§6). | M |
| Credentials (in `source` rows) | **Adapt** | Move them to the Keychain on iOS and tvOS ([doc](https://developer.apple.com/documentation/security/keychain-services)). design.md already planned to revisit this for a signed release. iCloud Keychain could share them with the Apple TV. | S–M |
| TunerCore/Services: Sync, Guide, StreamResolver, M3UExporter | **Reuse** | Scheduling changes in the app layer: the 10-minute loop doesn't run while suspended. Sync on `scenePhase == .active`, and use `BGAppRefreshTask` (~30 s) for small refreshes and `BGProcessingTask` for full syncs. | S |
| TunerCore/Services/RecordingService (209) | **Rewrite (engine)** | Keep the scheduler and DB logic. Put the `Process` path under `#if os(macOS)` and add a libavformat recorder; gate iOS behaviour as in §3. | L (deferrable) |
| CZlib | **Reuse** | zlib is in every SDK | — |
| CMPV (dlopen shim) | **macOS only** | iOS/tvOS use MPVKit's `Libmpv` module instead | S |
| App/TunerApp + AppDelegate (68) | **Rewrite per platform** | iOS App struct; `UIApplicationDelegateAdaptor` for the audio session and BG tasks; no `Settings` scene | S |
| App/AppModel (654) | **Adapt** | Replace `NSApp`/`NSWindow` (`toggleFullScreen`, `isActive`) with `scenePhase`. **Reminders** must be scheduled ahead of time with `UNCalendarNotificationTrigger`; today's 15-second in-app tick posts them immediately, which won't run while suspended. Keep the 64 pending-notification cap in mind: schedule the soonest ones and re-plan on foreground ([UILocalNotification doc](https://developer.apple.com/documentation/uikit/uilocalnotification), [forum](https://developer.apple.com/forums/thread/811171)). Auto-switch only works in the foreground. Tapping the notification should deep-link to the channel. | M |
| App/Preferences (177) | **Adapt** | Recordings path moves to Documents; drop the Homebrew-related text | S |
| App/KeyboardShortcuts (440) | **Rewrite** | Keep `TunerCommands`, which becomes the iPad menu bar. Replace the `NSEvent` single-key monitor with `.onKeyPress` on the focused player or guide. Drop the remapping editor on iOS at first. | M |
| App/NowPlaying (168) | **Adapt** | Same MediaPlayer API on iOS ([doc](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)). Change `NSImage` to `UIImage` and set `MPNowPlayingInfoPropertyIsLiveStream` for live TV. tvOS PiP requires an `MPNowPlayingSession` ([WWDC20 10176](https://developer.apple.com/videos/play/wwdc2020/10176/)). | S |
| App/RootView, Navigation (274) | **Rewrite (shell)** | iOS: `TabView` with `.sidebarAdaptable` (§5). Keep the persistent player overlay concept and drop `WindowAccessor`. | M |
| Player/PlaybackEngine, PlaybackItem, PlayerManager (284) | **Reuse** | Change `NSView` to `PlatformView`; layout limits per device type | S |
| Player/PlayerSlot (821) | **Reuse** | Routing, watchdog and failover are platform-neutral. Change the `NSView` usage and swap `ffmpegPath()` checks for remuxer availability. | S |
| Player/AVEngine (1042) | **Adapt** | `UIView` host, audio session, PiP auto-start, background detach. Error mapping reused. **Flag:** it passes the undocumented asset option `"AVURLAssetHTTPHeaderFieldsKey"` (for Referer). Widely used, but it's private API surface and a small review/regression risk. `AVURLAssetHTTPUserAgentKey` is public. | M |
| Player/MPVEngine (549) | **Adapt** | Core options, events, tracks and snapshot reused (about 70%). Swap the options: `hwdec=videotoolbox`, `ao=audiounit`, remove the macOS-specific ones. | M |
| Player/MPVVideoLayer (302) | **Rewrite** | EAGL/GLES3 → `CVOpenGLESTextureCache` FBO ring → `AVSampleBufferDisplayLayer` and sample-buffer PiP | L |
| Player/AirPlayBridge (249) | **Rewrite (engine)** | Keep `HLSFileServer` (NWListener) and `lanAddress()`; replace the `Process` with the `Remuxer` | L (deferrable) |
| Player/SlotVideoView (136) | **Adapt** | `UIViewRepresentable` container with the same claim-if-on-screen ownership logic | S |
| Views/Live (2106) | **Adapt** | Grid constants (230 pt channel column, 64 pt rows) need compact variants. iPhone portrait: channel list with now/next and progress instead of the grid. iPad: grid with preview header as on Mac. `.focusable`/`.onKeyPress` already work with iPad keyboards. Replace `onExitCommand` (macOS/tvOS only). | L |
| Views/Player (2161) | **Rewrite (interaction)** | Hover and `NSEvent`-driven auto-hide become tap-to-toggle. Gestures: double-tap left/right ±10 s, vertical swipe to zap channels, pinch for fill/fit, scrub on the timeline. Swipe down for the mini player; on iPhone the mini player goes in `tabViewBottomAccessory` (iOS 26+, [doc](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:))). The glass chrome visuals are reused. | L |
| Views/VOD (3810) | **Adapt** | Mostly plain SwiftUI. Change `NSWorkspace` to `openURL`, `NSPasteboard` to `UIPasteboard`, `NSImage` to `UIImage`; adaptive grid columns; `backgroundExtensionEffect` is iOS 26+. | M |
| Views/Settings (2737) | **Adapt** | `Form`/`.grouped` is portable. Replace the panels with `.fileImporter`/`.fileExporter` and swap the macOS-only control styles. Present Settings as a tab or sheet. Drop the shortcut editor on iPhone. | M–L |
| Views/Recordings (492) | **Adapt** | Reveal-in-Finder becomes the Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`, [doc](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled)) or a share sheet | S–M |
| Views/Common, Support (311) | **Adapt** | `tunerGlass` already checks `#available(macOS 26)`; add the iOS 26 equivalent | S |

---

## 5. iPad and iPhone UX ("like the Apple TV app")

**Navigation shell**
- `TabView` + `.tabViewStyle(.sidebarAdaptable)` (iOS/tvOS 18+, [doc](https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable)).
  - On iPad this gives the TV app's top tab bar that expands to a sidebar.
  - On iPhone it is a bottom tab bar; on tvOS, a sidebar.
- Tabs: Home · Live TV · Movies · TV Shows · Search (`role: .search`) · a `TabSection("Channels")` with Favorites, Recently Watched and custom groups (shown in the sidebar).
- iOS 27 adds `Tab(role: .prominent)` ([WWDC26 269](https://developer.apple.com/videos/play/wwdc2026/269/)).
- Keep `NavigationSplitView` on macOS for now. `.sidebarAdaptable` also exists on macOS 15, so the shells could be unified later.

**Player**
- A full-screen custom player with the existing glass chrome, rather than `AVPlayerViewController`. A custom player is needed because:
  - the mpv engine and multiview can't live inside `AVPlayerViewController`;
  - one chrome across both engines keeps the experience consistent.
- `AVPlayerViewController` would give system controls, PiP, AirPlay and Now Playing for free ([doc](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)). Use it on tvOS for AVFoundation content (§6).
- iPhone:
  - Enter landscape on play with `requestGeometryUpdate` ([doc](https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:))).
  - In iOS 27, orientation is only a preference and is ignored in resizable contexts ([WWDC26 278](https://developer.apple.com/videos/play/wwdc2026/278/)), so **lay out by size class, not by orientation**.
- PiP must start only from a user action, never programmatically; App Review rejects programmatic starts ([doc](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)).
- Rename the in-app "Picture in Picture" multiview layout (for example "Inset") so it isn't confused with system PiP.

**iPad**
- Multiview: 2×2 and main + 3 on iPad only (§2.3).
- Window resizing: support Stage Manager/iPadOS 26 resizable windows. `UIRequiresFullScreen` now only gives a scaled compatibility mode ([doc](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequiresfullscreen)).
- The UIScene lifecycle is mandatory with the 27 SDK; SwiftUI's `App` already complies ([TN3187](https://developer.apple.com/documentation/technotes/tn3187-migrating-to-the-uikit-scene-based-life-cycle)).
- Multiple windows (`UIApplicationSupportsMultipleScenes`) clash with "one persistent video view per slot". Defer them.
- Hardware keyboard: `TunerCommands` becomes the iPadOS 26 menu bar. Apple's guidance is to disable menu items rather than hide them ([WWDC25 208](https://developer.apple.com/videos/play/wwdc2025/208/)).
- Pointer: `.onHover` works with a trackpad (iOS 13.4+); add `.hoverEffect` ([doc](https://developer.apple.com/documentation/swiftui/view/hovereffect(_:isenabled:))). Every hover-only affordance (guide cell highlight, scrub preview) needs a touch equivalent.
- External display: playing on a connected display needs, from iOS 27, a `UISceneAccessory` registration ([doc](https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display)). AirPlay covers most of this need, so it is low priority.

**Design**
- Liquid Glass (`glassEffect`, `tabBarMinimizeBehavior`, `backgroundExtensionEffect`) is iOS 26+. The 27 SDK ignores the compatibility opt-out `UIDesignRequiresCompatibility` ([doc](https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility)).
- **Guideline 5.2.5:** don't make a confusingly similar copy of an Apple app. Follow the Apple TV app's patterns, not its exact look.

---

## 6. tvOS: what carries over

| Area | Carry-over |
|---|---|
| TunerCore (parsing, providers, sync, EPG, metadata) | ✅ about 100% |
| AVEngine, PlayerSlot routing, NowPlaying | ✅ mostly. Use `AVPlayerViewController` with `customInfoViewControllers` / `transportBarCustomMenuItems` for a native TV player ([doc](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/custominfoviewcontrollers)). |
| mpv | ✅ MPVKit supports tvOS 15+, and AerioTV ships on tvOS. The GLES path exists on tvOS (also deprecated). Sample-buffer PiP on tvOS is documented, but one project reports it isn't honoured (**UNVERIFIED**). |
| WebKit | Not available on tvOS ([doc](https://developer.apple.com/documentation/webkit/wkwebview)). **Tuner uses no WebKit**; the only match is a MAG user-agent string. ✅ |
| Storage | **Big difference.** No guaranteed persistent local storage beyond about 500 KB of user defaults. Caches can be purged while the app isn't running ([Apple TV programming guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html)). The library/EPG DB must be rebuildable from Caches (your account re-syncs in about 25 s). Keep sources, favourites and progress in iCloud key-value storage or CloudKit, and credentials in the Keychain. |
| UI | ❌ Mostly new interaction design: focus engine (`focusable`, `@FocusState`, `focusSection`), `onMoveCommand`/`onPlayPauseCommand`/`onExitCommand`, and Siri Remote-only usability (guideline 2.4.3). Cards and shelves partly reuse; the guide grid needs focus work. |
| Notifications | tvOS notifications can't show a title, body or sound ([doc](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/title)), so reminders are in-app only |
| Extras | Top Shelf (`TVTopShelfContentProvider`) for Continue Watching and favourite channels. No local-network prompt on tvOS (TN3179). |

**Verdict:** the core and engines are close to free. The UI is a separate L-sized project (2–4 weeks). Do it after the iPad build is stable.

---

## 7. App Store and licensing risks

### 7.1 Review risks (guidelines last updated 2026-06-08, [link](https://developer.apple.com/app-store/review/guidelines/))

| Risk | Guideline | Likelihood | Mitigation |
|---|---|---|---|
| "Facilitates unauthorised access to streams" | 5.2.2 / 5.2.3 | Medium | Ship with **no** playlists, channels or logos. Put a "provides no content" statement in the description, the empty state and the Terms (as IPTVX and UHF do). Give App Review your own test server: M3U, XMLTV and Xtream test credentials serving only Apple's [BipBop HLS examples](https://developer.apple.com/streaming/examples/) and Blender CC-BY films. **Do not** use iptv-org lists; its own README says the links are user-submitted. |
| Recording / offline download | 5.2.3 (no saving media from third-party sources without authorisation) | Medium–High | Leave DVR and download out of iOS v1. Flex IPTV is approved while advertising recording, so it is not automatically fatal. |
| Screenshots showing real channels or posters | 2.3.9, 5.2.1 | High if done | Make screenshots from the demo server with invented channel names and logos |
| Metadata services | 5.2.2 | Medium | TMDB needs a **separate commercial agreement** if the app earns money, plus attribution ([terms](https://www.themoviedb.org/api-terms-of-use)). Cinemeta has no published terms for third-party apps (**UNVERIFIED** that it's allowed): get permission or make TMDB the only source. |
| ATS exception | ATS docs | Low–Medium | Justification is required for `NSAllowsArbitraryLoads` ([doc](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads)). Reason to give: "user-supplied third-party IPTV servers we don't control, which commonly use plain HTTP and raw IPs". See §8 for the exact key set. |
| Background audio misuse | 2.5.4 | Low | Enable "Audio, AirPlay, and Picture in Picture" only when PiP, AirPlay and background audio actually work. Apple has asked for videos demonstrating this ([forum](https://developer.apple.com/forums/thread/26315)). |
| Looking like Apple's TV app | 5.2.5 | Low–Medium | Use the patterns, not a pixel copy |
| Age rating | 2025 questionnaire (13+/16+/18+) | — | `hideAdultContent` already exists. Add a PIN and declare Parental Controls. Don't declare unrestricted web access ([age ratings](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)). |
| Rights-holder takedowns | legal, not Apple policy | Low for a small app | Popular players were removed by court orders (Spain 2022–24, [TorrentFreak](https://torrentfreak.com/laliga-targets-apple-google-bosses-for-failing-to-remote-delete-iptv-app-240422/); India March 2026: 36 apps). Keep "Xtream"/"Stalker" out of the app name and keywords, and mention them only as supported formats. |
| EU DSA trader status | App Store Connect | Required | You must declare a status. A trader must publish a verified address, phone and email ([doc](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)). |
| Undocumented `AVURLAssetHTTPHeaderFieldsKey` | 2.5.1 (public APIs) | Low | Widely used in shipping apps. Keep it, but be aware it can break without notice. |

Comparable approved apps (iTunes lookup, 2026-10-01):
- iPlayTV and iPlayTV AIO (Xtream + Stalker + TMDB, 4+).
- IPTVX (subscription, "WE DO NOT PROVIDE CONTENT").
- UHF (requires legally sourced playlists; KSPlayer licensee).
- GSE Smart IPTV (only a CC-BY sample).
- AerioTV (MPVKit, iOS/iPadOS/tvOS).

### 7.2 Licensing: be precise

**What not to ship**
- **GPL is out for the App Store.** That rules out MPVKit-GPL, KSPlayer without the paid licence, mpv's default GPL build and FFmpeg with `--enable-gpl` ([FSF](https://www.fsf.org/news/2010-05-app-store-compliance); VLC was pulled in 2011 and returned after relicensing to LGPL, [VideoLAN](https://www.videolan.org/press/lgpl-libvlc.html)).
- **Use MPVKit ≥ 1.0.0 only.** Earlier "LGPL" builds still had `--enable-nonfree`, which makes the result **unredistributable**. That was fixed in [PR #78](https://github.com/mpvkit/MPVKit/pull/78) on 2026-07-11, and the fix was verified on macOS only. Check the iOS slice's `avcodec_configuration()` string yourself.

**What MPVKit's LGPL build obliges you to do**
- MPVKit's LGPL product is **LGPLv3**, because FFmpeg is built with `--enable-version3`. It ships **static** frameworks.
- **Relinkability.** LGPL requires that users can relink the app against a modified library: LGPLv3 §4(d)(0) / LGPLv2.1 §6(a) ([text](https://www.gnu.org/licenses/lgpl-3.0.html)).
  - With static linking, offer the app's object files (or its source).
  - Re-packaging MPVKit as dynamic frameworks is the other route. Whether an embedded, code-signed dynamic framework counts as a "suitable shared library mechanism" is debatable (**UNVERIFIED**).
- **Attribution and source.** Include licence texts and a source offer for FFmpeg, mpv, libplacebo, MoltenVK and the other bundled components in an About/Acknowledgements screen ([FFmpeg legal checklist](https://ffmpeg.org/legal.html)).
- **EULA.** LGPL requires terms that permit reverse engineering for debugging modifications. Apple's standard EULA forbids reverse engineering except "to the extent as may be permitted by the licensing terms governing use of any open-sourced components" ([Apple standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), verified 2026-10-01). That carve-out helps. A custom EULA must keep an equivalent clause.
- **LGPLv3 §4(e) "Installation Information"** applies only where GPLv3 §6 would require it. That is object code conveyed as part of a transaction transferring a *User Product*, and App Store distribution doesn't transfer the device. My reading is that it doesn't apply. **Get counsel.** VLCKit (LGPLv2.1) avoids the question entirely.

**Patents**
- FFmpeg's legal page warns about patents for commercial use.
- Prefer VideoToolbox hardware decode for H.264 and HEVC; Apple's hardware decoders are licensed.
- The last AC-3 patents expired in 2017. E-AC-3 and DTS status is **UNVERIFIED**.

**Simplest compliance**
- If you open-source Tuner under a permissive licence (MIT or Apache), the relinking requirement is met by the public source.
- A GPL-licensed app conflicts with the App Store.

**macOS today:** dlopen'ing a user-installed libmpv and running a user-installed ffmpeg means Tuner distributes neither. That changes the moment either is bundled.

---

## 8. iOS platform constraints: the checklist

1. **ATS: keep exactly one key, `NSAllowsArbitraryLoads = YES`, as the macOS Info.plist already does.**
   - Do **not** add `NSAllowsLocalNetworking` or `NSAllowsArbitraryLoadsForMedia`. On iOS 10+ their presence makes the system ignore `NSAllowsArbitraryLoads`. That would block plain-HTTP playlist and guide downloads, and on iOS 17+ also block raw-IP hosts, which iOS 17 no longer allows by default and which many IPTV panels use ([NSAllowsLocalNetworking doc](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking), verified 2026-10-01).
   - *(One research thread suggested adding NSAllowsLocalNetworking for the bridge. That would be wrong for Tuner. ArbitraryLoads already permits LAN/IP loads.)*
   - ATS governs URLSession and AVPlayer: mediaserverd honours the app's exceptions ([forum](https://developer.apple.com/forums/thread/51613)). It does not cover Network.framework or BSD sockets (libmpv/FFmpeg) ([doc](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)).
2. **Local network:** keep `NSLocalNetworkUsageDescription` for LAN IPTV sources (TVHeadend, HDHomeRun, a local Xtream). A plain `NWListener` doesn't need it; Bonjour would need `NSBonjourServices` ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
3. **Audio session and background:**
   - `AVAudioSession` category `.playback`, mode `.moviePlayback`, plus the "Audio, AirPlay, and Picture in Picture" background mode ([doc](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)).
   - Use the `.longFormAudio` route-sharing policy for AirPlay ([doc](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app)).
   - In the background without PiP, detach the AVPlayerLayer and set mpv `vid=no` to keep audio playing.
4. **PiP:** AVPlayerLayer, or sample-buffer content for mpv. User-initiated only. Can auto-start on swipe home.
5. **Reminders:** schedule `UNCalendarNotificationTrigger` notifications ahead of time. Respect the 64 pending cap. `.timeSensitive` needs an entitlement and users can turn it off ([doc](https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive)).
6. **Background sync:** expect data to be stale when the app opens. Show cached data immediately and sync on activation. `BGAppRefreshTask` gets about 30 s; `BGProcessingTask` runs only when the device is idle.
7. **Multiple players:** no documented limit; handle `decoderTemporarilyUnavailable`.
8. **AirPlay:** native for AVPlayer URLs. Custom headers don't reach the receiver. The bridge needs the LAN IP and the app staying alive (§3).
9. **Storage:**
   - Application Support: library DB (excluded from backup) and user DB (backed up).
   - Caches: artwork (`URLCache`).
   - Documents: recordings, exposed in Files.
   - Keychain: credentials.
   - `tmp`: bridge segments, already used today.
   - ([File system overview](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html))
10. **Memory (UNVERIFIED, measure it):** jetsam limits on iPhones are much tighter than on a Mac. Profile a full sync of a 12k-channel / 41k-movie / 15k-series account and guide ingest on an older device before assuming the macOS numbers (25 s) hold.

---

## 9. Phased plan

| Phase | Scope | Exit criteria | Size |
|---|---|---|---|
| **0. Toolchain & restructure** | You accept the Xcode licence, select Xcode and download the iOS runtime; enrol in the Developer Program. Split the package (`TunerPlayback`, `TunerUI`); add `platforms`; `PlatformView` shim; `#if os(macOS)` around `Process`; create `Tuner.xcodeproj` with an empty iOS target. | `TunerCore` tests pass on the iOS simulator (`xcodebuild test -scheme TunerCore -destination 'platform=iOS Simulator,name=iPad Pro…'`), and the macOS app still builds with `scripts/build-app.sh`. | S–M (3–5 days) |
| **1. iPhone/iPad MVP, AVFoundation only** | TabView shell; Home/Movies/TV Shows/Search; Live (iPhone list, iPad grid + preview); AVEngine port; touch player chrome; audio session, PiP, AirPlay, Now Playing; Settings with fileImporter and Keychain credentials; reminders as scheduled notifications; DB split. | TestFlight (internal) build plays your Xtream live (H.264 HLS) and MP4 VOD; PiP, AirPlay, lock-screen controls and resume work. | L (2–3 weeks) |
| **2. MPVKit fallback** | MPVKit LGPL 1.0.x; GLES render API → CVPixelBuffer → AVSampleBufferDisplayLayer renderer; sample-buffer PiP; reuse routing and fallback; acknowledgements screen; measure binary size and memory. | Your MKV movies and raw-TS channels play on iPhone and iPad, with PiP for mpv content and automatic fallback as on Mac. | L (2–3 weeks) |
| **3. In-process remuxer** | libavformat `Remuxer` on MPVKit's FFmpeg; AirPlay bridge on iOS (LAN URL); optional MKV(H.264/HEVC) → AVPlayer route; replace `Process(ffmpeg)` on macOS too, if you accept bundling FFmpeg there. | An MKV movie AirPlays from iPhone to an Apple TV; no Homebrew ffmpeg is needed on the Mac. | L (~2 weeks) |
| **4. iPad polish** | Multiview 2×2 / main + 3; menu-bar commands; keyboard focus in the guide; pointer hover effects; Stage Manager resizing; mini player. | Works with a Magic Keyboard / trackpad, and the layout holds in any window size. | M (1 week) |
| **5. App Store readiness** (if public) | Demo server; screenshots with invented content; privacy policy; age rating; DSA status; review notes; TMDB/Cinemeta terms; ATS justification text. | Submitted. | M (≈1 week) |
| **6. tvOS** | Focus UI; AVPlayerViewController with info panels; Caches + iCloud storage strategy; Top Shelf. | Usable with the Siri Remote only. | L (2–4 weeks) |
| **Later** | iOS recording (foreground, with playback, or `BGContinuedProcessingTask`), or Mac-as-DVR server with iOS as client. | — | L |

---

## 10. Open questions for the owner

1. **Distribution:** public App Store, or personal use (TestFlight / dev-signed on your own devices)? Personal use removes most of §7, and GPL builds, DVR and Cinemeta become non-issues. This is the biggest fork in the plan.
2. **Open source?** If Tuner's source will be public under a permissive licence, LGPL compliance for the static MPVKit frameworks is simple. If not, you need an object-file relinking offer or a dynamic-framework repackage.
3. **Monetisation?** It triggers TMDB's commercial agreement, IAP rules (3.1.1) and likely EU "trader" status with a public address and phone.
4. **Minimum OS:** I suggest **iOS/iPadOS 18 / tvOS 18**. That is the `.sidebarAdaptable` floor and matches the macOS 15 floor. Liquid Glass extras would sit behind `#available(iOS 26)`. Going straight to 26 simplifies the code but drops older devices. Which do you prefer?
5. **DVR on iPhone:** is it a must? If yes, choose between "records only while Tuner is open or playing" and "the Mac records, the iPhone schedules and plays back".
6. **Order:** do you want tvOS before iPad polish?
7. **Engine fallback:** are you comfortable with mpv on the deprecated GLES path (shipping today, with VLCKit 4 as plan B)? Or would you rather wait for VLCKit 4 stable, or pay for KSPlayer's LGPL licence?
8. **Mac impact:** OK to switch the active developer directory to Xcode? Also, should the macOS app eventually move to bundled MPVKit instead of Homebrew libmpv? That gives one engine everywhere and a notarisable Mac app, at the cost of carrying LGPL obligations on macOS.
9. **Apple Developer Program:** are you already enrolled (needed for device testing beyond 7 days, TestFlight and the App Store)?

---

### Uncertainties to resolve by experiment (not by more reading)

- Whether an Apple TV pulls bridge segments from a phone's `NWListener` reliably, including while the phone is locked.
- GLES render API → AVSBDL performance for 4K HEVC on an A-series iPhone, and power use compared with AVPlayer.
- How many simultaneous decoders a given iPad sustains for 2×2.
- Peak memory of a full sync and guide ingest on an older iPhone.
- Whether MPVKit 1.0.x's iOS slice is truly built without `--enable-nonfree`.
