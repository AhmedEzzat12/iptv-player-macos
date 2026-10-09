import SwiftUI
import TunerCore

/// iPhone full-screen player chrome, laid out like the TV app's player on iPhone (portrait and landscape):
/// close and a capsule of AirPlay / picture in picture / more at the top, the transport large in the middle,
/// and at the bottom the title, a capsule of speed / audio & subtitles / rotate, the timeline with the times
/// beside it, and pill buttons (Episodes, Next Episode). No panel: one even dim over the whole picture, so
/// there are no scrim edges. Hardware buttons set the volume. Never used on the Mac.
struct PlayerPhoneChrome: View {
    @Environment(AppModel.self) private var model
    let chrome: PlayerChromeController
    let stageSize: CGSize
    /// Safe area of the stage (clear of the Dynamic Island, status bar and home indicator).
    let safe: CGRect
    let isShown: Bool
    /// Height the bottom block covers from the bottom of the safe area (status cards and panels keep clear).
    let onBottomHeight: (CGFloat) -> Void

    private static let edge: CGFloat = 20
    private static let control: CGFloat = 44

    var body: some View {
        let slot = model.player.main
        let content = safe.insetBy(dx: Self.edge, dy: 0)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.32)
                .frame(width: stageSize.width, height: stageSize.height)
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                .frame(width: stageSize.width, height: stageSize.height * 0.4)
                .position(x: stageSize.width / 2, y: stageSize.height * 0.8)
                .allowsHitTesting(false)

            if let item = slot.item {
                // As in the TV app, the controls drift in from the edges and the transport scales up as they appear.
                PlayerPhoneTopBar(slot: slot, item: item, chrome: chrome, isShown: isShown, size: Self.control)
                    .padding(.top, 12)
                    .offset(y: isShown ? 0 : -14)
                    .playerPlaced(in: content, alignment: .top)

                // The episode list takes the screen's side or height; the transport and timeline step aside
                // (tapping the video closes the list).
                if !model.player.isEpisodeListOpen {
                    PlayerCenterTransport(slot: slot, chrome: chrome)
                        .scaleEffect(isShown ? 1 : 0.86)
                        .position(x: stageSize.width / 2, y: stageSize.height / 2)

                    PlayerPhoneBottomBlock(slot: slot, item: item, chrome: chrome, size: Self.control)
                        .padding(.bottom, 12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onBottomHeight($0 + 12) }
                        .offset(y: isShown ? 0 : 14)
                        .playerPlaced(in: content, alignment: .bottom)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: model.player.isEpisodeListOpen) { _, open in
            if open { onBottomHeight(0) }
        }
        .frame(width: stageSize.width, height: stageSize.height, alignment: .topLeading)
        .foregroundStyle(.white)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
    }
}

// MARK: - Top

private struct PlayerPhoneTopBar: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let item: PlaybackItem
    let chrome: PlayerChromeController
    let isShown: Bool
    let size: CGFloat
    @ViewState private var isFavorite = false

    var body: some View {
        // Engine switches change PiP/AirPlay availability; `viewToken`/`phase` make this view re-evaluate.
        let _ = (slot.viewToken, slot.phase)
        HStack(spacing: 10) {
            // Live TV keeps playing in the mini player; anything else stops.
            Button { if let close = chrome.requestClose { close() } else { model.exitFullWindow() } } label: {
                Image(systemName: item.isLive ? "chevron.down" : "xmark")
            }
            .buttonStyle(PlayerGlassButtonStyle(size: size))
            .accessibilityLabel(item.isLive ? "Minimize" : "Close Player")

            HStack(spacing: 2) {
                if slot.isPictureInPicturePossible {
                    let active = slot.isPictureInPictureActive
                    Button { slot.togglePictureInPicture() } label: {
                        PlayerGlassSymbol(symbol: active ? "pip.exit" : "pip.enter", size: size, glass: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(active ? "Exit Picture in Picture" : "Picture in Picture")
                }
                if isShown {
                    PlayerAirPlayControl(slot: slot, size: size, glass: false)
                }
                PlayerMoreMenu(slot: slot, size: size)
            }
            .padding(.horizontal, 4)
            .playerGlass(in: Capsule())

            Spacer(minLength: 8)

            if item.isLive, let channel = item.channel {
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
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .task(id: "\(channel.id)#\(model.userRevision)") {
                    isFavorite = (try? await model.db.channel(id: channel.id))?.isFavorite ?? channel.isFavorite
                }
            }
        }
    }
}

// MARK: - Bottom

private struct PlayerPhoneBottomBlock: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    /// Compact height = an iPhone in landscape.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    let slot: PlayerSlot
    let item: PlaybackItem
    let chrome: PlayerChromeController
    let size: CGFloat

    private var isLandscape: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private var isEpisode: Bool { model.currentEpisode != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: isLandscape ? 10 : 14) {
            HStack(alignment: .bottom, spacing: 12) {
                titles
                Spacer(minLength: 8)
                trailingGroup
            }
            if item.isLive {
                PlayerLiveTimeline(slot: slot, compact: true)
            } else {
                PlayerScrubber(slot: slot, chrome: chrome, inlineTimes: true)
            }
            if isEpisode {
                pills
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(isLandscape ? .title2.weight(.bold) : .title3.weight(.bold))
                    .lineLimit(1)
                if case .catchup = item { PlayerTag(text: "CATCH-UP") }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String? {
        if item.isLive { return item.channel?.number.map { "Channel \($0)" } }
        return item.subtitle
    }

    /// Speed, audio & subtitles and rotate, sharing one glass capsule.
    private var trailingGroup: some View {
        HStack(spacing: 2) {
            if !item.isLive {
                PlayerPhoneSpeedMenu(slot: slot, size: size)
            }
            PlayerTracksMenu(slot: slot, size: size, glass: false)
            #if os(iOS)
            // Full screen = landscape, as in YouTube; the same button (or swiping down) goes back.
            Button {
                PlayerOrientation.toggle()
                chrome.touch()
            } label: {
                PlayerGlassSymbol(symbol: isLandscape ? "arrow.down.right.and.arrow.up.left"
                                                      : "arrow.up.left.and.arrow.down.right", size: size, glass: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isLandscape ? "Exit Full Screen" : "Full Screen")
            #endif
        }
        .padding(.horizontal, 4)
        .playerGlass(in: Capsule())
    }

    private var pills: some View {
        let next = model.adjacentEpisode(1)
        return HStack(spacing: 10) {
            pill(model.player.isEpisodeListOpen ? "Hide Episodes" : "Episodes", symbol: "rectangle.stack") {
                withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen.toggle() }
            }
            if next != nil {
                pill("Next Episode", symbol: "forward.end.fill") { model.playAdjacentEpisode(1) }
            }
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            chrome.touch()
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .playerGlass(in: Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Playback speed: a gauge glyph at normal speed, the rate ("1.5×") otherwise.
private struct PlayerPhoneSpeedMenu: View {
    let slot: PlayerSlot
    let size: CGFloat
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        @Bindable var slot = slot
        Menu {
            Picker("Playback Speed", selection: $slot.rate) {
                ForEach(Self.rates, id: \.self) { rate in Text(PlayerSpeedMenu.label(rate)).tag(rate) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if slot.rate == 1 {
                PlayerGlassSymbol(symbol: "gauge.with.dots.needle.67percent", size: size, glass: false)
            } else {
                Text(PlayerSpeedMenu.label(slot.rate))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: size, minHeight: size)
                    .contentShape(Rectangle())
            }
        }
        .playerMenuStyle()
        .accessibilityLabel("Playback Speed")
    }
}

/// "…": aspect ratio and statistics.
struct PlayerMoreMenu: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let size: CGFloat

    var body: some View {
        @Bindable var slot = slot
        @Bindable var player = model.player
        Menu {
            Picker(selection: $slot.aspect) {
                ForEach(VideoAspect.allCases) { aspect in Text(aspect.title).tag(aspect) }
            } label: {
                Label("Aspect Ratio", systemImage: "aspectratio")
            }
            .pickerStyle(.menu)
            Divider()
            Toggle(isOn: $player.showStats) {
                Label("Playback Statistics", systemImage: "info.circle")
            }
        } label: {
            PlayerGlassSymbol(symbol: "ellipsis", size: size, glass: false)
        }
        .playerMenuStyle()
        .accessibilityLabel("More")
    }
}
