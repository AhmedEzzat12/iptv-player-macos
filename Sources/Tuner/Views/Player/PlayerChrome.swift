#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

// MARK: - Chrome state

/// Auto-hiding chrome state for the full-window player, shared by the stage, top bar and control panel.
@MainActor
@Observable
final class PlayerChromeController {
    private(set) var isVisible = true
    var isHoveringControls = false
    var isInteracting = false
    var isMenuOpen = false
    @ObservationIgnored private(set) var lastActivity = Date()
    @ObservationIgnored private var lastPointer: CGPoint?
    /// Pointer location when the user explicitly hid the chrome; small jitter around it is ignored.
    @ObservationIgnored private var hiddenAt: CGPoint?

    var isPinnedByUser: Bool { isHoveringControls || isInteracting || isMenuOpen }

    func pointerMoved(to location: CGPoint) {
        defer { lastPointer = location }
        if let anchor = hiddenAt {
            guard hypot(location.x - anchor.x, location.y - anchor.y) > 12 else { return }
            hiddenAt = nil
        }
        touch()
    }

    // Touch screens answer a tap faster than the Mac's pointer-driven fades (as in the TV app on iPhone).
    #if os(macOS)
    private static let showDuration = 0.25
    private static let hideDuration = 0.45
    #else
    private static let showDuration = 0.18
    private static let hideDuration = 0.25
    #endif

    /// Activity: shows the chrome and restarts the hide timer.
    func touch() {
        lastActivity = Date()
        if !isVisible { withAnimation(.easeOut(duration: Self.showDuration)) { isVisible = true } }
    }

    /// Click on the video.
    func toggle() {
        if isVisible {
            hide()
            hiddenAt = lastPointer
        } else {
            hiddenAt = nil
            touch()
        }
    }

    func hide() {
        guard isVisible else { return }
        withAnimation(.easeInOut(duration: Self.hideDuration)) { isVisible = false }
    }

    func reset() {
        hiddenAt = nil
        isHoveringControls = false
        isInteracting = false
        touch()
    }

    /// Safety net: a drag whose end event never arrived must not pin the chrome forever.
    func clearStaleInteraction() {
        if isInteracting, Date().timeIntervalSince(lastActivity) > 10 { isInteracting = false }
    }
}

enum PlayerChromeMetrics {
    static let topBarTop: CGFloat = 16
    static let topBarHeight: CGFloat = 44
    static var topBarBottom: CGFloat { topBarTop + topBarHeight }
}

// MARK: - Chrome

/// Full-window chrome: scrims, top bar (back, layout, PiP, AirPlay, stats) and the bottom control panel.
struct PlayerChrome: View {
    @Environment(AppModel.self) private var model
    let chrome: PlayerChromeController
    let stageSize: CGSize
    /// Detail column in stage coordinates.
    let safe: CGRect
    /// Area of the main cell the control panel sits in.
    let controlsRect: CGRect
    let isShown: Bool
    let isWindowFullScreen: Bool
    let onPanelHeight: (CGFloat) -> Void
    @Environment(\.tunerCompact) private var phone

    var body: some View {
        let main = model.player.main
        let compact = controlsRect.width < 640 || controlsRect.height < 460
        let topScrim = safe.minY + 150
        let bottomScrim = min(controlsRect.height, compact ? 220 : 320)

        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black.opacity(0.6), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(width: stageSize.width, height: topScrim)
                .position(x: stageSize.width / 2, y: topScrim / 2)
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .frame(width: controlsRect.width, height: bottomScrim)
                .position(x: controlsRect.midX, y: controlsRect.maxY - bottomScrim / 2)
                .allowsHitTesting(false)

            PlayerTopBar(chrome: chrome, slot: main, isShown: isShown)
                .padding(.horizontal, 20)
                .frame(width: safe.width, height: PlayerChromeMetrics.topBarHeight)
                .position(x: safe.midX, y: safe.minY + PlayerChromeMetrics.topBarTop + PlayerChromeMetrics.topBarHeight / 2)

            // Phones: the transport sits large in the middle of the video (PlayerTouchControls.swift).
            if phone, main.item != nil {
                PlayerCenterTransport(slot: main, chrome: chrome)
                    .position(x: controlsRect.midX, y: controlsRect.midY)
            }

            if main.item != nil {
                PlayerControlPanel(slot: main, chrome: chrome, compact: compact, isWindowFullScreen: isWindowFullScreen)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onPanelHeight($0) }
                    .padding(.horizontal, compact ? 12 : 20)
                    .padding(.bottom, compact ? 12 : 20)
                    .playerPlaced(in: controlsRect, alignment: .bottom)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height, alignment: .topLeading)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
    }
}

// MARK: - Top bar

private struct PlayerTopBar: View {
    @Environment(AppModel.self) private var model
    let chrome: PlayerChromeController
    let slot: PlayerSlot
    /// The AirPlay picker is an AppKit view; only mount it while the chrome is visible so the
    /// invisible chrome can't swallow clicks.
    let isShown: Bool
    @Environment(\.tunerCompact) private var phone

    var body: some View {
        @Bindable var player = model.player
        // Engine switches change PiP/AirPlay availability; `viewToken`/`phase` make this view re-evaluate.
        let _ = (slot.viewToken, slot.phase)
        let stopsOnExit = slot.item?.isLive == false

        HStack(spacing: 10) {
            Button(action: leavePlayer) {
                Image(systemName: stopsOnExit ? "xmark" : "chevron.backward")
            }
            .buttonStyle(PlayerGlassButtonStyle(size: 44))
            .help(stopsOnExit ? "Close Player" : "Back")
            .accessibilityLabel(stopsOnExit ? "Close Player" : "Back")

            Spacer(minLength: 12)


            if slot.isPictureInPicturePossible {
                let active = slot.isPictureInPictureActive
                Button { slot.togglePictureInPicture() } label: {
                    Image(systemName: active ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(PlayerGlassButtonStyle(size: 40))
                .help(active ? "Exit Picture in Picture" : "Picture in Picture")
            }

            if isShown {
                if let engine = slot.avEngineIfActive {
                    // Native engine: the system AirPlay device picker.
                    PlayerAirPlayButton(player: engine.player)
                        .frame(width: 26, height: 26)
                        .frame(width: 40, height: 40)
                        .playerGlass(in: Circle(), interactive: true)
                        .help("AirPlay")
                } else if slot.item != nil {
                    // mpv engine: AirPlay video needs Apple's player — reopen the stream in it when possible.
                    Button(action: prepareAirPlay) {
                        Image(systemName: "airplayvideo")
                    }
                    .buttonStyle(PlayerGlassButtonStyle(size: 40))
                    .help(slot.isAirPlayEligible || slot.canBridgeForAirPlay ? "AirPlay" : "AirPlay isn't available for this format")
                    .opacity(slot.isAirPlayEligible || slot.canBridgeForAirPlay ? 1 : 0.55)
                }
            }

            if phone {
                PlayerMoreMenu(slot: slot)
            } else {
                Button { player.showStats.toggle() } label: {
                    Image(systemName: player.showStats ? "info.circle.fill" : "info.circle")
                }
                .buttonStyle(PlayerGlassButtonStyle(size: 40))
                .help(player.showStats ? "Hide Statistics" : "Show Statistics")
            }
        }
        .onHover { chrome.isHoveringControls = $0 }
    }

    /// Same as Esc: leave macOS full screen and the full-window player.
    private func prepareAirPlay() {
        switch slot.prepareForAirPlay() {
        case .ready:
            break
        case .switching:
            model.notify(Banner(symbol: "airplayvideo", title: "Preparing AirPlay…",
                                message: "Switching this stream to Apple's player so it can be sent to AirPlay devices."))
        case .bridging:
            model.notify(Banner(symbol: "airplayvideo", title: "Preparing AirPlay…",
                                message: "Re-wrapping this stream for AirPlay devices on your Mac (no quality loss). It takes a few seconds."))
        case .unsupported(let message):
            model.notify(Banner(symbol: "airplayvideo", title: "AirPlay isn't available", message: message, isError: true))
        }
    }

    private func leavePlayer() {
        if let window = model.mainWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        model.exitFullWindow()
    }
}

// MARK: - Control panel

/// The glass control panel for the main slot.
struct PlayerControlPanel: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let chrome: PlayerChromeController
    let compact: Bool

    /// "Next Channel (Page Down)", following the user's key bindings.
    private func shortcutHelp(_ title: String, _ action: ShortcutAction) -> String {
        let key = model.prefs.key(for: action)
        return key.isEmpty ? title : "\(title) (\(ShortcutKey.label(key)))"
    }
    let isWindowFullScreen: Bool
    @Environment(\.tunerCompact) private var phone

    var body: some View {
        if let item = slot.item {
            let shape = RoundedRectangle(cornerRadius: compact ? 22 : 28, style: .continuous)
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                PlayerInfoRow(slot: slot, item: item, compact: compact)
                if item.isLive {
                    PlayerLiveTimeline(slot: slot, compact: compact)
                } else {
                    PlayerScrubber(slot: slot, chrome: chrome)
                }
                if phone {
                    PlayerTouchControlRow(slot: slot, chrome: chrome)
                } else {
                    transport(item)
                }
            }
            .padding(compact ? 14 : 20)
            .frame(maxWidth: compact ? 640 : 920)
            .background(Color.black.opacity(0.22), in: shape)
            .playerGlass(in: shape)
            .foregroundStyle(.white)
            .onHover { chrome.isHoveringControls = $0 }
        }
    }

    private func transport(_ item: PlaybackItem) -> some View {
        let side: CGFloat = compact ? 32 : 40
        let skip: CGFloat = compact ? 36 : 44
        let paused = slot.phase == .paused
        let ended = slot.phase == .ended
        let failed: Bool = {
            if case .failed = slot.phase { return true }
            return false
        }()
        let playSymbol = failed ? "arrow.clockwise" : (ended ? "arrow.counterclockwise" : (paused ? "play.fill" : "pause.fill"))
        let playTitle = failed ? "Try Again" : (ended ? "Replay" : (paused ? "Play" : "Pause"))
        return ZStack {
            HStack(spacing: compact ? 6 : 8) {
                PlayerTracksMenu(slot: slot, size: side)
                PlayerAspectMenu(slot: slot, size: side)
                if isEpisode {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen.toggle() }
                        chrome.touch()
                    } label: {
                        PlayerGlassSymbol(symbol: model.player.isEpisodeListOpen ? "rectangle.stack.fill" : "rectangle.stack", size: side)
                    }
                    .buttonStyle(.plain)
                    .help("Episodes")
                    .accessibilityLabel("Episodes")
                }
                if !item.isLive, !compact { PlayerSpeedMenu(slot: slot, height: side) }
                Spacer(minLength: 0)
                PlayerVolumeControl(slot: slot, chrome: chrome, buttonSize: side, sliderWidth: compact ? nil : 110)
                Button { model.toggleWindowFullScreen() } label: {
                    Image(systemName: isWindowFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(PlayerTransportButtonStyle(size: side, iconSize: side * 0.42))
                .help(isWindowFullScreen ? "Exit Full Screen" : "Enter Full Screen")
            }

            HStack(spacing: compact ? 10 : 18) {
                if item.isLive {
                    Button { model.channelUp(); chrome.touch() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(PlayerTransportButtonStyle(size: skip, iconSize: skip * 0.45))
                        .disabled(model.zapList.isEmpty)
                        .help(shortcutHelp("Previous Channel", .channelUp))
                } else {
                    if isEpisode { episodeButton(-1, skip: skip) }
                    Button { slot.seek(by: -10); chrome.touch() } label: { Image(systemName: "gobackward.10") }
                        .buttonStyle(PlayerTransportButtonStyle(size: skip, iconSize: skip * 0.5))
                        .disabled(!slot.canSeek)
                        .help("Back 10 Seconds (←)")
                }

                Button {
                    if failed { slot.retry() } else { slot.togglePause() }
                    chrome.touch()
                } label: {
                    Image(systemName: playSymbol)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerGlassButtonStyle(size: compact ? 46 : 58))
                .help(failed ? playTitle : "\(playTitle) (Space)")
                .accessibilityLabel(playTitle)

                if item.isLive {
                    Button { model.channelDown(); chrome.touch() } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(PlayerTransportButtonStyle(size: skip, iconSize: skip * 0.45))
                        .disabled(model.zapList.isEmpty)
                        .help(shortcutHelp("Next Channel", .channelDown))
                } else {
                    Button { slot.seek(by: 10); chrome.touch() } label: { Image(systemName: "goforward.10") }
                        .buttonStyle(PlayerTransportButtonStyle(size: skip, iconSize: skip * 0.5))
                        .disabled(!slot.canSeek)
                        .help("Forward 10 Seconds (→)")
                    if isEpisode { episodeButton(1, skip: skip) }
                }
            }
        }
    }

    private var isEpisode: Bool { model.currentEpisode != nil && slot === model.player.main }

    /// ⏮ / ⏭ for series: previous or next episode (across seasons), with its code and title as the tooltip.
    private func episodeButton(_ offset: Int, skip: CGFloat) -> some View {
        let target = model.adjacentEpisode(offset)
        let title = offset < 0 ? "Previous Episode" : "Next Episode"
        return Button { model.playAdjacentEpisode(offset); chrome.touch() } label: {
            Image(systemName: offset < 0 ? "backward.end.fill" : "forward.end.fill")
        }
        .buttonStyle(PlayerTransportButtonStyle(size: skip, iconSize: skip * 0.42))
        .disabled(target == nil)
        .help(target.map { "\(title): \(VODFormat.episodeCode($0)) · \($0.title)" } ?? title)
        .accessibilityLabel(title)
    }
}

/// Artwork, title/subtitle and (live) favourite + record.
private struct PlayerInfoRow: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let item: PlaybackItem
    let compact: Bool
    @ViewState private var isFavorite = false
    @ViewState private var loadedChannelId: String?

    var body: some View {
        HStack(spacing: 12) {
            if !compact { artwork }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(compact ? .headline : .title3.weight(.semibold))
                        .lineLimit(1)
                    if case .catchup = item { PlayerTag(text: "CATCH-UP") }
                    if case .recording = item { PlayerTag(text: "RECORDING") }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.isLive, let channel = item.channel {
                liveActions(channel)
            }
        }
        .task(id: favoriteKey) { await refreshFavorite() }
    }

    private var subtitle: String? {
        if item.isLive { return item.channel?.number.map { "Channel \($0)" } }
        return item.subtitle
    }

    @ViewBuilder
    private var artwork: some View {
        if item.isLive, let channel = item.channel {
            ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 40)
        } else {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            RemoteImage(url: item.artworkURL, contentMode: .fill) {
                shape.fill(.white.opacity(0.08))
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
            .frame(width: 96, height: 54)
            .clipShape(shape)
        }
    }

    private var placeholderSymbol: String {
        switch item {
        case .recording: "record.circle"
        case .episode: "tv"
        case .catchup, .channel: "clock.arrow.circlepath"
        case .movie: "film"
        }
    }

    @ViewBuilder
    private func liveActions(_ channel: Channel) -> some View {
        let size: CGFloat = compact ? 30 : 36
        let recording = model.recordings.first { $0.channelId == channel.id && $0.status == .recording }
        HStack(spacing: 8) {
            Button {
                var current = channel
                current.isFavorite = isFavorite
                model.toggleFavorite(current)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.white)
            }
            .buttonStyle(PlayerGlassButtonStyle(size: size))
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")

            #if os(macOS)
            Button {
                if let recording { model.cancelRecording(recording) } else { model.recordNow(channel) }
            } label: {
                Image(systemName: recording != nil ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recording != nil ? Color.red : Color.white)
                    .symbolEffect(.pulse, isActive: recording != nil)
            }
            .buttonStyle(PlayerGlassButtonStyle(size: size))
            .help(recording != nil ? "Stop Recording" : "Record Now")
            #endif
        }
    }

    /// The playing item's `Channel` is a snapshot; re-read the favourite flag when user data changes.
    private var favoriteKey: String {
        "\(item.channel?.id ?? "")#\(model.userRevision)"
    }

    private func refreshFavorite() async {
        guard let channel = item.channel else { return }
        if loadedChannelId != channel.id {
            loadedChannelId = channel.id
            isFavorite = channel.isFavorite
        }
        if let fresh = try? await model.db.channel(id: channel.id) {
            isFavorite = fresh.isFavorite
        }
    }
}

/// Live: LIVE pill, programme title, time range, progress and time left.
private struct PlayerLiveTimeline: View {
    let slot: PlayerSlot
    let compact: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 10) {
                PlayerLivePill()
                if let program = slot.currentProgram {
                    Text(program.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !compact {
                        Text(Fmt.timeRange(program.start, program.end))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize()
                    }
                    ProgressCapsule(fraction: program.progress(at: context.date), height: 4, tint: .white)
                        .frame(minWidth: 40)
                    Text(Fmt.remaining(until: program.end, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                } else {
                    Text("No program information")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 22)
        }
    }
}
