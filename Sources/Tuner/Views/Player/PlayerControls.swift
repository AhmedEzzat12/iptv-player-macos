import AppKit
import SwiftUI
import TunerCore

// Reusable player controls: scrubber, volume, track/aspect/speed menus, glass and button styles.

// MARK: - Scrubber

/// VOD/catch-up/recording timeline: drag or click to seek, hover shows the time under the pointer.
struct PlayerScrubber: View {
    let slot: PlayerSlot
    let chrome: PlayerChromeController
    @ViewState private var dragFraction: Double?
    @ViewState private var pendingFraction: Double?
    @ViewState private var pendingToken = 0
    @ViewState private var hoverX: CGFloat?

    var body: some View {
        let snapshot = slot.snapshot
        let duration = snapshot.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let position = max(0, snapshot.position ?? 0)
        let fraction = dragFraction ?? pendingFraction ?? duration.map { min(1, position / $0) } ?? 0
        let shownTime = duration.map { fraction * $0 } ?? position
        let buffered = duration.map { min(1, max(0, (snapshot.bufferedEnd ?? 0) / $0)) } ?? 0

        VStack(spacing: 6) {
            track(fraction: fraction, buffered: buffered, duration: duration)
            HStack {
                Text(Fmt.clock(shownTime))
                Spacer()
                Text(duration.map { "−" + Fmt.clock(max(0, $0 - shownTime)) } ?? "--:--")
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func track(fraction: Double, buffered: Double, duration: Double?) -> some View {
        let canSeek = duration != nil && slot.canSeek
        return GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = canSeek && (dragFraction != nil || hoverX != nil)
            let barHeight: CGFloat = active ? 8 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule().fill(Color.white.opacity(0.3)).frame(width: width * buffered)
                Capsule().fill(Color.white).frame(width: max(barHeight, width * fraction))
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: width * fraction - 7)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if canSeek, let duration, let x = dragFraction.map({ CGFloat($0) * width }) ?? hoverX {
                    Text(Fmt.clock(duration * Double(min(1, max(0, x / width)))))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .playerGlass(in: Capsule())
                        .fixedSize()
                        .position(x: min(max(x, 30), width - 30), y: -16)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard canSeek else { return }
                        dragFraction = Double(min(1, max(0, value.location.x / width)))
                        chrome.isInteracting = true
                        chrome.touch()
                    }
                    .onEnded { value in
                        chrome.isInteracting = false
                        guard canSeek, let duration else { return }
                        let target = Double(min(1, max(0, value.location.x / width)))
                        slot.seek(to: target * duration)
                        dragFraction = nil
                        holdPosition(target)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 18)
    }

    /// Shows the seek target until the engine reports the new position (avoids a jump back).
    private func holdPosition(_ fraction: Double) {
        pendingFraction = fraction
        pendingToken += 1
        let token = pendingToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if pendingToken == token { pendingFraction = nil }
        }
    }
}

// MARK: - Volume

struct PlayerVolumeControl: View {
    @Environment(AppModel.self) private var model
    let slot: PlayerSlot
    let chrome: PlayerChromeController
    var buttonSize: CGFloat = 36
    /// nil: mute button only.
    var sliderWidth: CGFloat? = 110

    var body: some View {
        let level = slot.isMuted ? 0 : slot.volume
        HStack(spacing: 4) {
            Button { slot.isMuted.toggle() } label: {
                Image(systemName: Self.symbol(for: level))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerTransportButtonStyle(size: buttonSize, iconSize: buttonSize * 0.42))
            .help(slot.isMuted ? "Unmute (M)" : "Mute (M)")

            if let sliderWidth {
                PlayerCapsuleSlider(
                    fraction: level / 150,
                    marker: 100.0 / 150,
                    onChange: { fraction in
                        slot.volume = (fraction * 150).rounded()
                        if slot.isMuted, fraction > 0 { slot.isMuted = false }
                        chrome.isInteracting = true
                        chrome.touch()
                    },
                    onEnd: {
                        model.prefs.volume = slot.volume
                        chrome.isInteracting = false
                    }
                )
                .frame(width: sliderWidth)
                .help("Volume \(Int(level))%")
            }
        }
    }

    static func symbol(for level: Double) -> String {
        switch level {
        case ..<1: "speaker.slash.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// Thin capsule slider (0…1) that thickens on hover; optional tick mark (e.g. 100 % volume).
struct PlayerCapsuleSlider: View {
    var fraction: Double
    var marker: Double?
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    @ViewState private var dragging = false
    @ViewState private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = dragging || hovering
            let barHeight: CGFloat = active ? 7 : 5
            let value = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white).frame(width: max(barHeight, width * value))
            }
            .frame(height: barHeight)
            .overlay(alignment: .leading) {
                if let marker {
                    Rectangle()
                        .fill(Color.white.opacity(value >= marker ? 0.0 : 0.45))
                        .frame(width: 1.5, height: barHeight + 4)
                        .offset(x: width * marker)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        onChange(Double(min(1, max(0, drag.location.x / width))))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEnd()
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 20)
    }
}

// MARK: - Menus

struct PlayerTracksMenu: View {
    let slot: PlayerSlot
    let size: CGFloat

    var body: some View {
        let audio = slot.audioTracks
        let subtitles = slot.subtitleTracks
        let subtitlesOn = subtitles.contains(where: \.isSelected)
        Menu {
            Section("Audio") {
                if audio.isEmpty {
                    Text("No Audio Tracks")
                } else {
                    Picker("Audio", selection: Binding(
                        get: { audio.first(where: \.isSelected)?.id ?? audio[0].id },
                        set: { slot.selectAudioTrack($0) }
                    )) {
                        ForEach(audio) { track in Text(track.label).tag(track.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section("Subtitles") {
                Picker("Subtitles", selection: Binding<Int?>(
                    get: { subtitles.first(where: \.isSelected)?.id },
                    set: { slot.selectSubtitleTrack($0) }
                )) {
                    Text("Off").tag(Int?.none)
                    ForEach(subtitles) { track in Text(track.label).tag(Int?.some(track.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            PlayerGlassSymbol(symbol: subtitlesOn ? "captions.bubble.fill" : "captions.bubble", size: size)
        }
        .playerMenuStyle()
        .help("Audio & Subtitles")
    }
}

struct PlayerAspectMenu: View {
    let slot: PlayerSlot
    let size: CGFloat

    var body: some View {
        @Bindable var slot = slot
        Menu {
            Picker("Aspect Ratio", selection: $slot.aspect) {
                ForEach(VideoAspect.allCases) { aspect in Text(aspect.title).tag(aspect) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PlayerGlassSymbol(symbol: "aspectratio", size: size)
        }
        .playerMenuStyle()
        .help("Aspect Ratio")
    }
}

struct PlayerSpeedMenu: View {
    let slot: PlayerSlot
    let height: CGFloat
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        @Bindable var slot = slot
        Menu {
            Picker("Playback Speed", selection: $slot.rate) {
                ForEach(Self.rates, id: \.self) { rate in Text(Self.label(rate)).tag(rate) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Self.label(slot.rate))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minWidth: height + 8)
                .frame(height: height)
                .playerGlass(in: Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .playerMenuStyle()
        .help("Playback Speed")
    }

    static func label(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass drawn *behind* the content (material before macOS 26). Unlike `tunerGlass`, the content
    /// isn't inside the glass, so the glass foreground treatment doesn't wash out tinted content — with
    /// `glassEffect` on the content, the red LIVE pill, yellow favourite star, red record dot and orange
    /// warnings render white/black.
    func playerGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        background { PlayerGlassBackground(shape: shape, interactive: interactive) }
    }

    func playerGlass(cornerRadius: CGFloat) -> some View {
        playerGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct PlayerGlassBackground<S: Shape>: View {
    let shape: S
    let interactive: Bool

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

// MARK: - Buttons

/// Glass circle used as a Menu label.
struct PlayerGlassSymbol: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.4).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .playerGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

extension View {
    /// Menu whose label is drawn as-is (glass circle/capsule), without the pop-up indicator.
    func playerMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Large tappable glass circle (Apple TV player look).
struct PlayerGlassButtonStyle: ButtonStyle {
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        PlayerGlassButtonBody(configuration: configuration, size: size)
    }
}

private struct PlayerGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: (size * 0.4).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .playerGlass(in: Circle(), interactive: true)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Borderless transport glyph with a soft hover circle.
struct PlayerTransportButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var iconSize: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        PlayerTransportButtonBody(configuration: configuration, size: size, iconSize: iconSize)
    }
}

private struct PlayerTransportButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let iconSize: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: iconSize.rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.24 : (hovering && isEnabled ? 0.12 : 0))))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
