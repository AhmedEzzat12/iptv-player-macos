#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVKit
import SwiftUI
import WebKit

// MARK: - Overlay

/// In-app trailer player, Apple TV app style: a dimmed, blurred full-window backdrop with the trailer at 16:9 in the
/// middle. YouTube trailers play in YouTube's official embedded player (IFrame Player API in a `WKWebView`),
/// direct video links in AVKit. `RootView` layers it above everything (player and banners included); it shows
/// while `model.trailer` is set. ✕, Esc and a click outside the video close it via `model.dismissTrailer()`.
struct TrailerOverlay: View {
    @Environment(AppModel.self) private var model
    @ViewState private var playback = TrailerPlaybackController()
    @ViewState private var escapeMonitor = TrailerEscapeMonitor()

    var body: some View {
        ZStack {
            if let request = model.trailer {
                Color.black.opacity(0.6)
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissTrailer() }
                    .transition(.opacity)

                TrailerPanel(request: request, playback: playback) { model.dismissTrailer() }
                    .id(request.id)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.3), value: model.trailer?.id)
        .onChange(of: model.trailer?.id, initial: true) { old, new in
            // AppKit video views ignore SwiftUI opacity: silence and fade the outgoing video while the
            // panel's removal transition runs; the views are torn down when it ends.
            if let old, old != new { playback.stop(old) }
            let model = model
            escapeMonitor.setEnabled(new != nil, window: model.mainWindow) { model.dismissTrailer() }
        }
        .onDisappear { escapeMonitor.setEnabled(false, window: nil) {} }
    }
}

/// Title row and the 16:9 video (or the fallback card), as large as the window allows.
private struct TrailerPanel: View {
    let request: TrailerRequest
    let playback: TrailerPlaybackController
    let close: () -> Void
    @ViewState private var failure: TrailerFailure?

    private var source: TrailerSource { TrailerSource(request.url) }
    private static let headerHeight: CGFloat = 52
    private static let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let size = videoSize(in: proxy.size)
            VStack(alignment: .leading, spacing: Self.spacing) {
                header
                    .frame(height: Self.headerHeight)
                video
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 36)
    }

    /// 16:9, filling the width or the height left under the title row, whichever runs out first.
    private func videoSize(in available: CGSize) -> CGSize {
        let maxHeight = max(0, available.height - Self.headerHeight - Self.spacing)
        let width = max(240, min(available.width, maxHeight * 16 / 9, 1920))
        return CGSize(width: width.rounded(), height: (width * 9 / 16).rounded())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trailer")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.6))
                Text(request.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            if failure == nil, case .youTube = source {
                Button {
                    openExternally()
                } label: {
                    Label("Open in YouTube", systemImage: "arrow.up.forward.square")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Watch this trailer on YouTube in your browser")
            }
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(GlassButtonStyle(circle: true))
            .help("Close (Esc)")
            .accessibilityLabel("Close Trailer")
        }
    }

    @ViewBuilder
    private var video: some View {
        if let failure {
            TrailerFallbackCard(failure: failure, source: source, open: openExternally)
                .transition(.opacity)
        } else {
            switch source {
            case .youTube(let id):
                YouTubeTrailerView(requestID: request.id, videoID: id, playback: playback,
                                   onEnded: close, onFailure: { failure = $0 })
            case .video(let url):
                NativeTrailerView(requestID: request.id, url: url, playback: playback,
                                  onEnded: close, onFailure: { failure = $0 })
            case .external:
                TrailerFallbackCard(failure: .unsupportedLink, source: source, open: openExternally)
            }
        }
    }

    /// Hands the trailer to the browser / YouTube and closes the overlay, so it doesn't keep playing here too.
    private func openExternally() {
        NSWorkspace.shared.open(source.externalURL)
        close()
    }
}

/// Shown in the video's place when the trailer can't play in the app.
private struct TrailerFallbackCard: View {
    let failure: TrailerFailure
    let source: TrailerSource
    let open: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TrailerVideoContainer.cornerRadius, style: .continuous)
                .fill(.black)
            VStack(spacing: 12) {
                Image(systemName: "play.slash.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text("This trailer can't play here")
                    .font(.title3.weight(.semibold))
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: open) {
                    Label(source.externalTitle, systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 420)
            .padding(24)
        }
    }
}

// MARK: - Sources

/// What a trailer link points at.
enum TrailerSource: Equatable {
    /// A YouTube video, played in YouTube's embedded player.
    case youTube(String)
    /// Any other http(s) link, tried in AVKit (MP4/MOV/HLS…); the fallback card offers the browser if it fails.
    case video(URL)
    /// A link the app can't play (a YouTube page without a video id, a non-web scheme).
    case external(URL)

    init(_ url: URL) {
        if let id = YouTubeEmbed.videoID(from: url) {
            self = .youTube(id)
        } else if YouTubeEmbed.isYouTube(url) || !["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            self = .external(url)
        } else {
            self = .video(url)
        }
    }

    var externalURL: URL {
        switch self {
        case .youTube(let id): YouTubeEmbed.watchURL(id)
        case .video(let url), .external(let url): url
        }
    }

    var externalTitle: String {
        switch self {
        case .youTube: "Open in YouTube"
        case .video(let url), .external(let url): YouTubeEmbed.isYouTube(url) ? "Open in YouTube" : "Open in Browser"
        }
    }
}

/// Why a trailer can't play in the app (IFrame Player API error codes, load failures).
enum TrailerFailure: Equatable {
    case invalidRequest
    case html5
    case notFound
    case notEmbeddable
    case configuration
    case unreachable
    case unplayable
    case unsupportedLink

    /// Maps an IFrame Player API `onError` code.
    init(youTubeCode code: Int) {
        switch code {
        case 2: self = .invalidRequest
        case 5: self = .html5
        case 100: self = .notFound
        case 101, 150: self = .notEmbeddable
        case 152, 153: self = .configuration
        default: self = .html5
        }
    }

    var message: String {
        switch self {
        case .invalidRequest: "YouTube didn't accept this trailer's video link."
        case .html5: "YouTube's player couldn't play this video here."
        case .notFound: "This video was removed or made private on YouTube."
        case .notEmbeddable: "Its owner only allows it to be watched on YouTube."
        case .configuration: "YouTube didn't allow its player to run in the app."
        case .unreachable: "YouTube couldn't be reached. Check your internet connection."
        case .unplayable: "The video couldn't be opened."
        case .unsupportedLink: "This link isn't a video the app can play."
        }
    }
}

// MARK: - YouTube

/// YouTube's official embedded player (IFrame Player API), loaded as an HTML string into a `WKWebView`.
///
/// YouTube refuses embeds that don't identify the app embedding them (errors 152/153, "Video player
/// configuration error"), and a WKWebView sends no Referer for a page without an origin. YouTube's documented
/// fix for native apps (developers.google.com/youtube/terms/required-minimum-functionality) is to load the page
/// with `loadHTMLString(_:baseURL:)` and an https base URL made from the bundle id; the IFrame API's `origin`
/// player parameter matches it. Without the base URL the player fails with 153.
enum YouTubeEmbed {
    static var baseURL: URL { URL(string: origin + "/")! }

    /// `https://app.tuner.macos` (the bundle id; `swift run` builds have none, so fall back to the app's).
    static var origin: String {
        let id = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        let valid = !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-") }
        return "https://" + (valid ? id : "app.tuner.macos")
    }

    static func watchURL(_ id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "youtu.be", "youtube-nocookie.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The video id in a watch?v=, youtu.be/, /embed/, /shorts/ (/v/, /live/) link, or a bare 11-character id.
    static func videoID(from url: URL) -> String? {
        guard url.host != nil else { return validID(url.absoluteString) }
        guard isYouTube(url), let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        if host == "youtu.be" || host.hasSuffix(".youtu.be") { return validID(path.first) }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return validID(v)
        }
        if path.count >= 2, ["embed", "shorts", "v", "e", "live"].contains(path[0].lowercased()) {
            return validID(path[1])
        }
        return nil
    }

    /// YouTube ids are 11 characters of `A–Z a–z 0–9 _ -` (which also keeps them safe to put in the page).
    static func validID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.count == 11,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { return nil }
        return value
    }

    static let messageHandler = "trailer"

    /// The player page: autoplay with sound (the web view allows it), no related videos from other channels,
    /// no annotations. Player events are posted to the `trailer` script message handler.
    static func html(videoID: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
        #player { position: absolute; inset: 0; width: 100%; height: 100%; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
        function post(message) { window.webkit.messageHandlers.\(messageHandler).postMessage(message); }
        var player;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: '100%',
            height: '100%',
            videoId: '\(videoID)',
            playerVars: { autoplay: 1, rel: 0, iv_load_policy: 3, fs: 1, origin: '\(origin)' },
            events: {
              onReady: function (event) { post({ event: 'ready' }); event.target.playVideo(); },
              onStateChange: function (event) { post({ event: 'state', state: event.data }); },
              onError: function (event) { post({ event: 'error', code: event.data }); }
            }
          });
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post({ event: 'apiError' })"></script>
        </body>
        </html>
        """
    }
}

private struct YouTubeTrailerView: NSViewRepresentable {
    let requestID: UUID
    let videoID: String
    let playback: TrailerPlaybackController
    let onEnded: () -> Void
    let onFailure: (TrailerFailure) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TrailerVideoContainer {
        let coordinator = context.coordinator
        coordinator.onEnded = onEnded
        coordinator.onFailure = onFailure

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(WeakScriptMessageHandler(coordinator), name: YouTubeEmbed.messageHandler)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.underPageBackgroundColor = .black

        let container = TrailerVideoContainer(content: webView)
        coordinator.webView = webView
        coordinator.container = container
        playback.attach(requestID, webView: webView, player: nil, container: container)
        webView.loadHTMLString(YouTubeEmbed.html(videoID: videoID), baseURL: YouTubeEmbed.baseURL)
        coordinator.startWatchdog()
        return container
    }

    func updateNSView(_ view: TrailerVideoContainer, context: Context) {
        context.coordinator.onEnded = onEnded
        context.coordinator.onFailure = onFailure
    }

    static func dismantleNSView(_ view: TrailerVideoContainer, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        weak var container: TrailerVideoContainer?
        var onEnded: (() -> Void)?
        var onFailure: ((TrailerFailure) -> Void)?
        private var isReady = false
        private var watchdog: Task<Void, Never>?

        /// No player within 20 s (YouTube unreachable, or an id the API silently ignores) → fallback card.
        func startWatchdog() {
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, !self.isReady else { return }
                self.fail(.unreachable)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            switch event {
            case "ready":
                isReady = true
                watchdog?.cancel()
            case "state":
                // YT.PlayerState.ENDED: back to the page, as the TV app does.
                if (body["state"] as? NSNumber)?.intValue == 0 { onEnded?() }
            case "error":
                fail(TrailerFailure(youTubeCode: (body["code"] as? NSNumber)?.intValue ?? -1))
            case "apiError":
                fail(.unreachable)
            default:
                break
            }
        }

        private func fail(_ failure: TrailerFailure) {
            watchdog?.cancel()
            silence()
            onFailure?(failure)
        }

        // Navigation: the player page and YouTube's iframe load here; links the player opens (title, logo,
        // "Watch on YouTube") go to the browser instead of replacing the page.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            guard isMainFrame, let url = navigationAction.request.url,
                  url != YouTubeEmbed.baseURL, url.scheme != "about" else {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            container?.fadeIn()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(.unreachable)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(.unreachable)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail(.unreachable)
        }

        private func silence() {
            webView?.pauseAllMediaPlayback(completionHandler: nil)
        }

        /// Stops the page for good: nothing may keep playing once the overlay is gone.
        func tearDown() {
            watchdog?.cancel()
            onEnded = nil
            onFailure = nil
            guard let webView else { return }
            webView.configuration.userContentController.removeScriptMessageHandler(forName: YouTubeEmbed.messageHandler)
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.pauseAllMediaPlayback(completionHandler: nil)
            webView.closeAllMediaPresentations(completionHandler: nil)
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            webView.removeFromSuperview()
            self.webView = nil
        }
    }
}

/// `WKUserContentController` retains its handlers; this keeps it from retaining the coordinator.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Direct video

#if os(macOS)
// (iOS: iOS/Sources/Support/TrailerPlatform.swift)
private struct NativeTrailerView: NSViewRepresentable {
    let requestID: UUID
    let url: URL
    let playback: TrailerPlaybackController
    let onEnded: () -> Void
    let onFailure: (TrailerFailure) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TrailerVideoContainer {
        let coordinator = context.coordinator
        coordinator.onEnded = onEnded
        coordinator.onFailure = onFailure

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.videoGravity = .resizeAspect
        playerView.player = player

        let container = TrailerVideoContainer(content: playerView)
        coordinator.observe(item, player: player, view: playerView)
        playback.attach(requestID, webView: nil, player: player, container: container)
        player.play()
        container.fadeIn()
        return container
    }

    func updateNSView(_ view: TrailerVideoContainer, context: Context) {
        context.coordinator.onEnded = onEnded
        context.coordinator.onFailure = onFailure
    }

    static func dismantleNSView(_ view: TrailerVideoContainer, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        var onEnded: (() -> Void)?
        var onFailure: ((TrailerFailure) -> Void)?
        private var player: AVPlayer?
        private weak var playerView: AVPlayerView?
        private var statusObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?

        func observe(_ item: AVPlayerItem, player: AVPlayer, view: AVPlayerView) {
            self.player = player
            playerView = view
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.player?.pause()
                    self.onFailure?(.unplayable)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnded?() }
            }
        }

        func tearDown() {
            onEnded = nil
            onFailure = nil
            statusObservation?.invalidate()
            statusObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playerView?.player = nil
            player = nil
        }
    }
}
#endif

// MARK: - AppKit plumbing

#if os(macOS)
// (iOS: iOS/Sources/Support/TrailerPlatform.swift)
/// Rounded black host for the trailer's AppKit video view. Corners are Core Animation properties and the fade
/// is the view's alpha: SwiftUI clip shapes drawn at an embedded AppKit view's rect cover it, and SwiftUI
/// opacity doesn't reach it (docs/design.md).
final class TrailerVideoContainer: NSView {
    static let cornerRadius: CGFloat = 14
    private let clip = NSView()

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        clip.alphaValue = 0
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
        content.frame = clip.bounds
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        clip.frame = bounds
    }

    func fadeIn() { fade(to: 1, duration: 0.3) }

    func fadeOut() { fade(to: 0, duration: 0.2) }

    private func fade(to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            clip.animator().alphaValue = alpha
        }
    }
}
#endif

/// The overlay's handle on the trailer's media, so dismissal silences it at once (the views themselves are
/// torn down only after the overlay's fade-out).
@MainActor
final class TrailerPlaybackController {
    private var requestID: UUID?
    private weak var webView: WKWebView?
    private weak var player: AVPlayer?
    private weak var container: TrailerVideoContainer?

    func attach(_ requestID: UUID, webView: WKWebView?, player: AVPlayer?, container: TrailerVideoContainer) {
        self.requestID = requestID
        self.webView = webView
        self.player = player
        self.container = container
    }

    /// Pauses and fades out the trailer for `requestID`, if it's still the attached one.
    func stop(_ requestID: UUID) {
        guard self.requestID == requestID else { return }
        webView?.pauseAllMediaPlayback(completionHandler: nil)
        player?.pause()
        container?.fadeOut()
        self.requestID = nil
    }
}

#if os(macOS)
// (iOS: iOS/Sources/Support/TrailerPlatform.swift)
/// Esc closes the trailer. A local key monitor, installed only while the trailer shows, so the key is consumed
/// here instead of reaching the app's own Esc handling (leaving the player). Esc in another window — such as
/// the web view's own full screen — is left alone.
@MainActor
final class TrailerEscapeMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?
    private var onEscape: (() -> Void)?

    func setEnabled(_ enabled: Bool, window: NSWindow?, onEscape: @escaping () -> Void) {
        self.window = window
        self.onEscape = onEscape
        if enabled, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isEscape = event.keyCode == 53
                    && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                guard isEscape else { return event }
                let windowNumber = event.windowNumber
                let handled = MainActor.assumeIsolated { self?.handleEscape(windowNumber: windowNumber) ?? false }
                return handled ? nil : event
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleEscape(windowNumber: Int) -> Bool {
        guard let target = window ?? NSApp.mainWindow, target.windowNumber == windowNumber else { return false }
        onEscape?()
        return true
    }
}
#endif
