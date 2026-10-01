import SwiftUI
import TunerCore

// MARK: - Status

/// Loading / reconnecting / buffering / failure / end-of-media overlay for one slot, sized to its cell.
/// Only the cards' buttons are hit-testable; everything else lets clicks through to the video.
struct PlayerStatusOverlay: View {
    let slot: PlayerSlot
    let size: CGSize
    /// "Close" on the failure card (live only).
    var onClose: (() -> Void)?

    var body: some View {
        let density = PlayerOverlayDensity(size)
        ZStack {
            switch slot.phase {
            case .loading:
                PlayerConnectingView(slot: slot, density: density)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            case .buffering:
                PlayerBufferingView(message: slot.statusMessage, density: density)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            case .failed(let message):
                PlayerFailureCard(slot: slot, message: message, density: density, onClose: onClose)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            case .ended:
                if let item = slot.item, !item.isLive {
                    PlayerEndedCard(slot: slot, item: item, density: density)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            case .idle, .playing, .paused:
                if let message = slot.statusMessage {
                    PlayerStatusCapsule(message: message, density: density)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.25), value: slot.phase)
        .animation(.easeInOut(duration: 0.25), value: slot.statusMessage)
    }
}

enum PlayerOverlayDensity {
    case regular
    case compact
    /// Bottom-row multiview cells, tiny previews.
    case tiny

    init(_ size: CGSize) {
        if size.width >= 480, size.height >= 300 {
            self = .regular
        } else if size.width >= 300, size.height >= 190 {
            self = .compact
        } else {
            self = .tiny
        }
    }

    var isRegular: Bool { self == .regular }
}

private struct PlayerConnectingView: View {
    let slot: PlayerSlot
    let density: PlayerOverlayDensity

    var body: some View {
        let item = slot.item
        ZStack {
            // Finite media: blurred artwork while the stream opens.
            if density.isRegular, let item, !item.isLive, let url = item.artworkURL {
                RemoteImage(url: url, contentMode: .fill) { Color.clear }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 30)
                    .opacity(0.35)
                    .clipped()
            }
            VStack(spacing: density.isRegular ? 14 : 8) {
                if density.isRegular, let channel = item?.channel {
                    ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 48)
                }
                ProgressView()
                    .controlSize(density == .regular ? .regular : .small)
                if density != .tiny {
                    VStack(spacing: 3) {
                        Text(slot.statusMessage ?? "Connecting…")
                            .font(density.isRegular ? .headline : .caption.weight(.semibold))
                        if let title = item?.title {
                            Text(title)
                                .font(density.isRegular ? .callout : .caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(density.isRegular ? 20 : 8)
            .frame(maxWidth: density.isRegular ? 380 : 240)
        }
        .foregroundStyle(.white)
    }
}

private struct PlayerBufferingView: View {
    let message: String?
    let density: PlayerOverlayDensity
    /// Brief buffering hiccups don't flash a spinner.
    @ViewState private var visible = false

    var body: some View {
        Group {
            if let message {
                PlayerStatusCapsule(message: message, density: density)
            } else {
                ProgressView()
                    .controlSize(density == .regular ? .regular : .small)
                    .padding(density == .regular ? 14 : 8)
                    .playerGlass(in: Circle())
            }
        }
        .opacity(visible || message != nil ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.2)) { visible = true }
        }
    }
}

/// Failover / reconnect status ("Switching to …", "Reconnecting (2/10)…").
private struct PlayerStatusCapsule: View {
    let message: String
    let density: PlayerOverlayDensity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(density.isRegular ? .callout.weight(.medium) : .caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, density.isRegular ? 16 : 10)
        .padding(.vertical, density.isRegular ? 9 : 6)
        .playerGlass(in: Capsule())
        .padding(8)
    }
}

private struct PlayerFailureCard: View {
    let slot: PlayerSlot
    let message: String
    let density: PlayerOverlayDensity
    let onClose: (() -> Void)?

    var body: some View {
        let isLive = slot.item?.isLive ?? false
        let regular = density.isRegular
        VStack(spacing: regular ? 12 : 6) {
            Image(systemName: isLive ? "antenna.radiowaves.left.and.right.slash" : "exclamationmark.triangle.fill")
                .font(.system(size: regular ? 30 : 18, weight: .semibold))
                .foregroundStyle(.orange)
            if density != .tiny {
                Text(isLive ? "Channel Unavailable" : "Can't Play This")
                    .font(regular ? .title3.weight(.semibold) : .callout.weight(.semibold))
                Text(message)
                    .font(regular ? .callout : .caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(regular ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Try Again") { slot.retry() }
                    .buttonStyle(PlayerCapsuleButtonStyle(prominent: true, small: !regular))
                if isLive, let onClose {
                    Button("Close", action: onClose)
                        .buttonStyle(PlayerCapsuleButtonStyle(prominent: false, small: !regular))
                }
            }
            .padding(.top, regular ? 4 : 0)
        }
        .foregroundStyle(.white)
        .padding(regular ? 24 : 12)
        .frame(maxWidth: regular ? 420 : 280)
        .playerGlass(cornerRadius: regular ? 24 : 16)
        .padding(regular ? 24 : 6)
        .help(message)
    }
}

private struct PlayerEndedCard: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let item: PlaybackItem
    let density: PlayerOverlayDensity
    @ViewState private var nextEpisode: Episode?

    var body: some View {
        let regular = density.isRegular
        VStack(spacing: regular ? 12 : 6) {
            if density != .tiny {
                Text(item.title)
                    .font(regular ? .title3.weight(.semibold) : .callout.weight(.semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button {
                    slot.play(item, startAt: 0)
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(PlayerCapsuleButtonStyle(prominent: nextEpisode == nil, small: !regular))

                if let next = nextEpisode, case .episode(let episode, let series) = item {
                    Button {
                        Task { await model.playNextEpisode(after: episode, in: series) }
                    } label: {
                        Label("Next Episode", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(PlayerCapsuleButtonStyle(prominent: true, small: !regular))
                    .help("S\(next.season), E\(next.number) · \(next.title)")
                }
            }
            if regular, let next = nextEpisode {
                Text("Up next: S\(next.season), E\(next.number) · \(next.title)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(regular ? 24 : 12)
        .frame(maxWidth: regular ? 440 : 300)
        .playerGlass(cornerRadius: regular ? 24 : 16)
        .task(id: item.id) { await loadNextEpisode() }
    }

    private func loadNextEpisode() async {
        guard case .episode(let episode, let series) = item,
              let episodes = try? await model.db.episodes(seriesId: series.id),
              let index = episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < episodes.count else {
            nextEpisode = nil
            return
        }
        nextEpisode = episodes[index + 1]
    }
}

/// Capsule button for overlay cards (white prominent / translucent secondary).
struct PlayerCapsuleButtonStyle: ButtonStyle {
    var prominent = true
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 14, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, small ? 12 : 18)
            .padding(.vertical, small ? 6 : 9)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(Capsule().fill(prominent
                ? Color.white.opacity(configuration.isPressed ? 0.75 : 1)
                : Color.white.opacity(configuration.isPressed ? 0.3 : 0.18)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

// MARK: - Channel banner

/// Shown top-leading for a few seconds after a zap in the full-window player.
struct PlayerChannelBanner: View {
    let slot: PlayerSlot

    var body: some View {
        if let channel = slot.item?.channel {
            HStack(spacing: 14) {
                ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let number = channel.number {
                            Text("\(number)")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Text(channel.displayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        PlayerLivePill()
                    }
                    if let program = slot.currentProgram {
                        HStack(spacing: 6) {
                            Text(program.title).lineLimit(1)
                            Text("·")
                            Text(Fmt.remaining(until: program.end)).monospacedDigit().fixedSize()
                        }
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        ProgressCapsule(fraction: program.progress(), height: 3, tint: .white)
                            .frame(width: 220)
                    } else {
                        Text("No program information")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .playerGlass(cornerRadius: 22)
            // Caps long names without stretching the glass for short ones.
            .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

// MARK: - Stats

/// Technical statistics for the main slot (toggle with I).
struct PlayerStatsPanel: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot

    var body: some View {
        let s = slot.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Statistics").font(.system(size: 12, weight: .bold))
                Spacer(minLength: 16)
                Button { model.player.showStats = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(PlayerTransportButtonStyle(size: 20, iconSize: 10))
                .help("Hide Statistics (I)")
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                row("Engine", slot.engineName.isEmpty ? "—" : slot.engineName)
                row("Resolution", s.videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "—")
                row("Video", s.videoCodec ?? "—")
                row("Audio", s.audioCodec ?? "—")
                row("Frame rate", s.fps.map { String(format: "%.2f fps", $0) } ?? "—")
                row("Video bitrate", Self.bitrate(s.videoBitrate))
                row("Audio bitrate", Self.bitrate(s.audioBitrate))
                row("Buffered", s.bufferedSeconds.map { String(format: "%.1f s", $0) } ?? "—")
                row("Decoder", Self.decoder(s.hardwareDecoder))
                row("Dropped", s.droppedFrames.map { "\($0) frames" } ?? "—")
                row("Host", slot.stream?.url.host() ?? (slot.stream?.url.isFileURL == true ? "Local file" : "—"))
                row("State", Self.describe(slot.phase))
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 290, alignment: .leading)
        .playerGlass(cornerRadius: 16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.55))
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    static func bitrate(_ bitsPerSecond: Double?) -> String {
        guard let bps = bitsPerSecond, bps.isFinite, bps > 0 else { return "—" }
        if bps >= 1_000_000 { return String(format: "%.2f Mbps", bps / 1_000_000) }
        return String(format: "%.0f kbps", bps / 1000)
    }

    static func decoder(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "—" }
        return name == "no" ? "Software" : "Hardware (\(name))"
    }

    static func describe(_ phase: PlayerSlot.Phase) -> String {
        switch phase {
        case .idle: "Idle"
        case .loading: "Loading"
        case .playing: "Playing"
        case .paused: "Paused"
        case .buffering: "Buffering"
        case .ended: "Ended"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

// MARK: - Pills

struct PlayerLivePill: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red))
            .fixedSize()
    }
}

struct PlayerTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.2)))
            .fixedSize()
    }
}
