import AppKit
import SwiftUI
import TunerCore

/// How the persistent player is presented over the detail column.
enum PlayerPresentationMode: Equatable {
    /// Fills the window (sidebar collapsed, toolbar hidden): multiview stage + Apple TV–style chrome.
    case full
    /// Main slot only, inside the Live TV guide's preview slot.
    case preview
    /// Main slot only, floating bottom-trailing.
    case mini
    /// Nothing playing.
    case hidden
}

/// Where one slot's video surface sits on the stage.
struct PlayerSlotPlacement: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat = 0
    var isVisible = true
    /// Drop shadow (mini player, picture-in-picture inset).
    var isElevated = false
    var zIndex: Double = 0
}

/// The single, persistent player overlay drawn over the whole detail column by `DetailRoot`.
///
/// All four slots' video surfaces live in one `ForEach` keyed by slot id and are never inserted or removed:
/// switching between full window, guide preview, mini player and multiview layouts only changes their
/// frame, corner radius and opacity, so the engine views are never recreated and playback never restarts.
///
/// Coordinates: the stage extends under the title bar (`ignoresSafeArea`); `safe` is the detail column
/// (the coordinate space of `previewRect` and `containerSize`) expressed in stage coordinates.
struct PlayerHost: View {
    @Environment(AppModel.self) private var model
    let previewRect: CGRect?
    let containerSize: CGSize

    @ViewState private var chrome = PlayerChromeController()
    @ViewState private var scrollMonitor = PlayerScrollVolumeMonitor()
    @ViewState private var panelHeight: CGFloat = 0
    @ViewState private var showZapBanner = false
    @ViewState private var zapBannerTask: Task<Void, Never>?
    @ViewState private var isWindowFullScreen = false

    var body: some View {
        GeometryReader { outer in
            let outerOrigin = outer.frame(in: .global).origin
            GeometryReader { inner in
                let innerOrigin = inner.frame(in: .global).origin
                let safe = CGRect(x: outerOrigin.x - innerOrigin.x, y: outerOrigin.y - innerOrigin.y,
                                  width: containerSize.width, height: containerSize.height)
                stage(size: inner.size, safe: safe)
            }
            .ignoresSafeArea()
        }
        .task(id: model.player.isFullWindow) { await runChromeAutoHide() }
        .onChange(of: model.player.isFullWindow, initial: true) { _, full in
            if full {
                chrome.reset()
            } else {
                showZapBanner = false
                PlayerTitlebar.setButtonsHidden(false, in: model.mainWindow)
            }
            let chrome = chrome
            // Pointer tracking uses an event monitor, not a SwiftUI hover region: a hover region over the
            // stage swallows clicks meant for the guide/library when the player isn't full window, and SwiftUI
            // hover can't see through the AppKit video views when it is.
            scrollMonitor.setEnabled(full, model: model, onActivity: { chrome.touch() },
                                     onPointer: { chrome.pointerMoved(to: $0) })
        }
        .onChange(of: model.channelChangeToken) { flashZapBanner() }
        .onChange(of: model.player.hasMedia) { _, hasMedia in
            if !hasMedia { recoverFromEmptyMain() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.mainWindow { isWindowFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if let window = note.object as? NSWindow, window === model.mainWindow { isWindowFullScreen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            chrome.isMenuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            chrome.isMenuOpen = false
            chrome.touch()
        }
        .onAppear {
            isWindowFullScreen = model.mainWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onDisappear {
            scrollMonitor.setEnabled(false, model: model, onActivity: {}, onPointer: { _ in })
            PlayerTitlebar.setButtonsHidden(false, in: model.mainWindow)
        }
    }

    // MARK: - Mode

    private var mode: PlayerPresentationMode {
        let player = model.player
        if player.isFullWindow { return .full }
        guard player.hasMedia else { return .hidden }
        return previewRect != nil ? .preview : .mini
    }

    /// Chrome stays up while paused/failed/ended or while the user works the controls.
    private var chromePinned: Bool {
        switch model.player.main.phase {
        case .paused, .ended, .failed: true
        default: chrome.isPinnedByUser || model.player.isEpisodeListOpen
        }
    }

    // MARK: - Stage

    @ViewBuilder
    private func stage(size: CGSize, safe: CGRect) -> some View {
        let player = model.player
        let mode = self.mode
        let isFull = mode == .full
        let bounds = CGRect(origin: .zero, size: size)
        let chromeShown = isFull && (chrome.isVisible || chromePinned)
        // Keep the picture-in-picture inset above the control panel while the chrome is up.
        let pipInset: CGFloat = chromeShown && panelHeight > 0 ? (size.height - safe.maxY) + 20 + panelHeight + 16 : 24
        let cells = MultiviewGeometry.rects(for: player.layout, in: bounds, pipBottomInset: pipInset)
        let compact = compactRect(for: mode, safe: safe)

        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(isFull ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleWindowFullScreen() }
                .onTapGesture {
                    // A click on the video closes the episode list first, like clicking outside a popover.
                    if model.player.isEpisodeListOpen {
                        withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen = false }
                    } else {
                        chrome.toggle()
                    }
                }
                .allowsHitTesting(isFull)

            // Structurally stable video surfaces — never move these into mode-specific branches.
            ForEach(player.slots) { slot in
                let placement = placement(for: slot, mode: mode, cells: cells, compact: compact, bounds: bounds)
                PlayerVideoSurface(slot: slot, placement: placement)
                    .zIndex(placement.zIndex)
            }

            if isFull {
                fullOverlay(size: size, safe: safe, cells: cells, chromeShown: chromeShown)
                    .zIndex(10)
            } else if mode != .hidden {
                PlayerCompactControls(slot: player.main, style: mode == .mini ? .mini : .preview, size: compact.size)
                    .frame(width: compact.width, height: compact.height)
                    .position(x: compact.midX, y: compact.midY)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(response: 0.5, dampingFraction: 0.86),
                   value: PlayerStageAnimationKey(mode: mode, layout: player.layout, order: player.order))
        .onChange(of: isFull && !chromeShown) { _, hidden in
            PlayerTitlebar.setButtonsHidden(hidden, in: model.mainWindow)
        }
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func fullOverlay(size: CGSize, safe: CGRect, cells: [CGRect], chromeShown: Bool) -> some View {
        let player = model.player
        let layout = player.layout
        let mainRect = cells.first ?? CGRect(origin: .zero, size: size)
        let clipped = mainRect.intersection(safe)
        // The control panel belongs to the main (audible) cell, so the other cells stay clickable.
        let controlsRect = clipped.isNull || clipped.width < 240 || clipped.height < 160 ? safe : clipped
        // Cell decorations stay clear of the top bar.
        let topReserve = safe.minY + PlayerChromeMetrics.topBarBottom + 10

        ZStack(alignment: .topLeading) {
            ForEach(Array(player.visibleSlots.enumerated()), id: \.element.id) { position, slot in
                let rect = cells[position]
                // The control panel lives in the main cell; keep status cards clear of it and the top bar.
                let coveredBottom = position == 0 && chromeShown && panelHeight > 0
                    ? min(rect.height * 0.5, max(0, rect.maxY - controlsRect.maxY) + panelHeight + 20) : 0
                let coveredTop = chromeShown ? min(rect.height * 0.3, max(0, topReserve - rect.minY)) : 0
                MultiviewCellOverlay(slot: slot, position: position, layout: layout, size: rect.size,
                                     topInset: max(10, topReserve - rect.minY),
                                     statusInsets: EdgeInsets(top: coveredTop, leading: 0, bottom: coveredBottom, trailing: 0),
                                     chrome: chrome, onClose: { close(slot) })
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .zIndex(position == 0 ? 0 : 1)
            }

            if player.main.isAirPlayActive {
                PlayerAirPlayActiveView(title: player.main.item?.title)
                    .frame(width: mainRect.width, height: mainRect.height)
                    .position(x: mainRect.midX, y: mainRect.midY)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }

            PlayerChrome(chrome: chrome, stageSize: size, safe: safe, controlsRect: controlsRect,
                         isShown: chromeShown, isWindowFullScreen: isWindowFullScreen,
                         onPanelHeight: { panelHeight = $0 })
                .zIndex(5)

            if showZapBanner, player.main.item?.isLive == true {
                PlayerChannelBanner(slot: player.main)
                    .padding(.leading, 20)
                    .padding(.top, PlayerChromeMetrics.topBarBottom + 14)
                    .playerPlaced(in: safe, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(6)
            }

            if player.showStats {
                PlayerStatsPanel(slot: player.main)
                    .padding(.trailing, 20)
                    .padding(.top, PlayerChromeMetrics.topBarBottom + 14)
                    .playerPlaced(in: safe, alignment: .topTrailing)
                    .transition(.opacity)
                    .zIndex(6)
            }

            if player.isEpisodeListOpen, let current = model.currentEpisode, let context = model.episodeContext,
               context.series.id == current.series.id {
                let top = PlayerChromeMetrics.topBarBottom + 14
                let bottom: CGFloat = chromeShown && panelHeight > 0 ? panelHeight + 36 : 24
                PlayerEpisodesPanel(context: context, current: current.episode)
                    .frame(width: min(440, safe.width - 40), height: max(220, safe.height - top - bottom))
                    .padding(.trailing, 20)
                    .padding(.top, top)
                    .playerPlaced(in: safe, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(7)
            }

            if let upNext = upNext {
                UpNextCard(next: upNext.next, series: upNext.series, secondsLeft: upNext.seconds,
                           countdown: model.prefs.upNextCountdown)
                    .padding(.trailing, 24)
                    .padding(.bottom, chromeShown && panelHeight > 0 ? panelHeight + 40 : 32)
                    .playerPlaced(in: safe, alignment: .bottomTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(8)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.35), value: upNext?.next.id)
    }

    /// The Up Next card's content while an episode is in its last seconds (see `UpNextCountdown`).
    private var upNext: (next: Episode, series: Series, seconds: Int)? {
        guard model.prefs.autoplayNextEpisode, model.player.layout == .single, !model.player.isEpisodeListOpen,
              let current = model.currentEpisode, model.upNextCancelledFor != current.episode.id,
              let next = model.adjacentEpisode(1),
              // Offline, only a downloaded next episode can play.
              !model.isOffline || model.isDownloaded(next.id) else { return nil }
        let main = model.player.main
        guard main.phase == .playing || main.phase == .paused || main.phase == .buffering,
              let seconds = UpNextCountdown.secondsLeft(position: main.snapshot.position, duration: main.snapshot.duration,
                                                        countdown: model.prefs.upNextCountdown) else { return nil }
        return (next, current.series, seconds)
    }

    // MARK: - Geometry

    private func compactRect(for mode: PlayerPresentationMode, safe: CGRect) -> CGRect {
        if let rect = previewRect, mode != .mini {
            return rect.offsetBy(dx: safe.minX, dy: safe.minY)
        }
        let width = min(340, max(200, safe.width * 0.45)).rounded()
        let height = (width * 9 / 16).rounded()
        return CGRect(x: safe.maxX - 20 - width, y: safe.maxY - 20 - height, width: width, height: height)
    }

    private func placement(for slot: PlayerSlot, mode: PlayerPresentationMode, cells: [CGRect],
                           compact: CGRect, bounds: CGRect) -> PlayerSlotPlacement {
        let player = model.player
        let position = player.order.firstIndex(of: slot.id) ?? 0
        switch mode {
        case .full:
            guard position < cells.count else {
                return PlayerSlotPlacement(rect: MultiviewGeometry.parkedRect(in: bounds), cornerRadius: 12, isVisible: false)
            }
            return PlayerSlotPlacement(
                rect: cells[position],
                cornerRadius: MultiviewGeometry.cornerRadius(for: player.layout, position: position),
                isVisible: true,
                isElevated: player.layout == .pictureInPicture && position == 1,
                zIndex: position == 0 ? 0 : 1
            )
        case .preview, .mini, .hidden:
            let isMain = position == 0
            // Park idle slots (and everything when hidden) off-screen. SwiftUI `opacity`/`zIndex` don't reach
            // embedded AppKit views, so an "invisible" video view would still cover or swallow clicks.
            guard isMain, mode != .hidden else {
                return PlayerSlotPlacement(rect: MultiviewGeometry.parkedRect(in: bounds), cornerRadius: 12, isVisible: false)
            }
            return PlayerSlotPlacement(
                rect: compact,
                cornerRadius: mode == .mini ? 14 : 12,
                isVisible: isMain && mode != .hidden,
                isElevated: isMain && mode == .mini,
                zIndex: isMain ? 1 : 0
            )
        }
    }

    // MARK: - Actions

    /// Closes a multiview cell. Closing the main cell promotes the next playing cell (or stops playback).
    private func close(_ slot: PlayerSlot) {
        let player = model.player
        guard let position = player.order.firstIndex(of: slot.id) else { return }
        if position == 0 {
            guard let next = (1..<player.layout.slotCount).first(where: { player.slot(at: $0).item != nil }) else {
                model.stopPlayback()
                return
            }
            player.promote(position: next)
        }
        slot.stop()
        if player.layout == .pictureInPicture, player.slot(at: 1).item == nil {
            player.layout = .single
        }
    }

    /// The main slot was stopped while the player covers the window.
    private func recoverFromEmptyMain() {
        let player = model.player
        guard player.isFullWindow, !player.hasMedia else { return }
        if let next = (1..<player.layout.slotCount).first(where: { player.slot(at: $0).item != nil }) {
            player.promote(position: next)
        } else {
            model.exitFullWindow()
        }
    }

    private func flashZapBanner() {
        guard model.player.isFullWindow, model.prefs.showChannelBannerOnZap else { return }
        zapBannerTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showZapBanner = true }
        zapBannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { showZapBanner = false }
        }
    }

    /// Hides the chrome (and the pointer) after 3 s without mouse movement.
    private func runChromeAutoHide() async {
        guard model.player.isFullWindow else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            chrome.clearStaleInteraction()
            guard chrome.isVisible, !chromePinned, Date().timeIntervalSince(chrome.lastActivity) >= 3 else { continue }
            chrome.hide()
            if NSApp.isActive, let window = model.mainWindow, window.isKeyWindow,
               window.frame.contains(NSEvent.mouseLocation) {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

// MARK: - Video surface

private struct PlayerStageAnimationKey: Equatable {
    var mode: PlayerPresentationMode
    var layout: MultiviewLayout
    var order: [Int]
}

/// One slot's engine view, placed on the stage. Not hit-testable; interaction lives in the overlays above.
private struct PlayerVideoSurface: View {
    let slot: PlayerSlot
    let placement: PlayerSlotPlacement

    var body: some View {
        SlotVideoView(slot: slot, cornerRadius: placement.cornerRadius, isElevated: placement.isElevated && placement.isVisible)
            .frame(width: max(placement.rect.width, 1), height: max(placement.rect.height, 1))
            .position(x: placement.rect.midX, y: placement.rect.midY)
            .opacity(placement.isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - AirPlay

/// Shown in place of the picture while video plays on an AirPlay device (the local layer is empty).
struct PlayerAirPlayActiveView: View {
    let title: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Text("Playing on AirPlay")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            if let title {
                Text(title).font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Helpers

extension View {
    /// Pins the view inside `rect` (stage coordinates) with the given alignment. The surrounding
    /// frame is not hit-testable, only the view's own content.
    func playerPlaced(in rect: CGRect, alignment: Alignment) -> some View {
        frame(width: max(rect.width, 0), height: max(rect.height, 0), alignment: alignment)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// Fades the traffic-light buttons with the full-window chrome (as the TV app does). Never in macOS
/// full screen, where the title bar already auto-hides.
@MainActor
enum PlayerTitlebar {
    static func setButtonsHidden(_ hidden: Bool, in window: NSWindow?) {
        guard let window else { return }
        let hide = hidden && !window.styleMask.contains(.fullScreen)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.isHidden != hide else { continue }
            button.isHidden = hide
        }
    }
}

/// Scroll wheel / trackpad vertical scrolling adjusts the main slot's volume while the player fills the window.
@MainActor
final class PlayerScrollVolumeMonitor {
    private var monitor: Any?
    private var moveMonitor: Any?
    private weak var model: AppModel?
    private var onActivity: (() -> Void)?
    private var onPointer: ((CGPoint) -> Void)?

    func setEnabled(_ enabled: Bool, model: AppModel, onActivity: @escaping () -> Void,
                    onPointer: @escaping (CGPoint) -> Void) {
        self.model = model
        self.onActivity = onActivity
        self.onPointer = onPointer
        if enabled, moveMonitor == nil {
            model.mainWindow?.acceptsMouseMovedEvents = true
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                let point = event.locationInWindow
                let window = event.windowNumber
                MainActor.assumeIsolated {
                    guard let self, self.model?.mainWindow?.windowNumber == window else { return }
                    self.onPointer?(point)
                }
                return event
            }
        } else if !enabled, let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
        }
        if enabled, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let input = ScrollInput(event)
                let consumed = MainActor.assumeIsolated { self?.handle(input) ?? false }
                return consumed ? nil : event
            }
        } else if !enabled, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ input: ScrollInput) -> Bool {
        guard let model, model.player.isFullWindow, model.player.hasMedia,
              model.mainWindow?.windowNumber == input.windowNumber else { return false }
        // The episode list scrolls; the wheel only changes the volume when nothing on screen needs it.
        guard !model.player.isEpisodeListOpen else { return false }
        // Momentum and mostly-horizontal scrolls are swallowed without changing the volume.
        guard !input.isMomentum, abs(input.deltaY) > abs(input.deltaX) else { return true }
        let direction: Double = input.isInverted ? -1 : 1
        let delta = Double(input.deltaY) * direction * (input.isPrecise ? 0.25 : 3)
        let main = model.player.main
        let volume = min(PlayerSlot.maxVolume, max(0, (main.volume + delta).rounded()))
        guard volume != main.volume else { return true }
        main.volume = volume
        if delta > 0, main.isMuted { main.isMuted = false }
        model.prefs.volume = volume
        onActivity?()
        return true
    }

    private struct ScrollInput {
        var deltaX: CGFloat
        var deltaY: CGFloat
        var isPrecise: Bool
        var isInverted: Bool
        var isMomentum: Bool
        var windowNumber: Int

        init(_ event: NSEvent) {
            deltaX = event.scrollingDeltaX
            deltaY = event.scrollingDeltaY
            isPrecise = event.hasPreciseScrollingDeltas
            isInverted = event.isDirectionInvertedFromDevice
            isMomentum = !event.momentumPhase.isEmpty
            windowNumber = event.windowNumber
        }
    }
}
