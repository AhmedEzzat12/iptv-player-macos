import SwiftUI
import TunerCore

/// `Category` alone is ambiguous with the Objective-C runtime type; use this in the app target.
typealias ChannelCategory = TunerCore.Category

// MARK: - Channel logo

/// Rounded logo tile with a letter fallback (dark logos get a light tile).
struct ChannelLogo: View {
    let url: String?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(.white.opacity(0.08))
            .overlay {
                RemoteImage(url: url, contentMode: .fit) {
                    Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(size * 0.1)
            }
            .frame(width: size * 1.4, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

// MARK: - Progress

/// Thin capsule progress bar (watch progress, programme progress).
struct ProgressCapsule: View {
    var fraction: Double
    var height: CGFloat = 4
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.white.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
        }
        .frame(height: height)
    }
}

// MARK: - Glass & hover

extension View {
    /// Liquid Glass on macOS 26+, translucent material before.
    /// The glass is drawn *behind* the content: applying `glassEffect` to the content itself also applies
    /// glass foreground effects, which wash out coloured content (red record dots, LIVE pills, stars).
    @ViewBuilder
    func tunerGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.background {
                Color.clear.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    func tunerGlass(cornerRadius: CGFloat = 16) -> some View {
        tunerGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Apple TV–style lift on hover.
    func hoverLift(scale: CGFloat = 1.04) -> some View {
        modifier(HoverLift(scale: scale))
    }
}

private struct HoverLift: ViewModifier {
    let scale: CGFloat
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.45 : 0.2), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .zIndex(hovering ? 1 : 0)
    }
}

// MARK: - Buttons

/// The white capsule "Play" button from the TV app.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .foregroundStyle(.black)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Capsule())
    }
}

/// Secondary translucent capsule/circle button.
struct GlassButtonStyle: ButtonStyle {
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, circle ? 10 : 18)
            .padding(.vertical, 10)
            .frame(minWidth: circle ? 40 : nil, minHeight: circle ? 40 : nil)
            .foregroundStyle(.white)
            .background(
                Group {
                    if circle { Circle().fill(.white.opacity(configuration.isPressed ? 0.3 : 0.16)) }
                    else { Capsule().fill(.white.opacity(configuration.isPressed ? 0.3 : 0.16)) }
                }
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Shelf header

struct ShelfHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.link)
            }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func timeRange(_ start: Date, _ end: Date) -> String { "\(time(start)) – \(time(end))" }

    /// "1h 52m", "45m"
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
    }

    /// "1:02:03", "4:05"
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "Today", "Tomorrow", "Wed 3 Oct"
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "35 min left"
    static func remaining(until end: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m left" : "\(minutes) min left"
    }
}

// MARK: - Player preview slot

/// The Live TV guide marks where the main player should appear with `.playerPreviewSlot()`. The slot reports
/// its rect in window coordinates; the window-level `PlayerHost` positions the (single, persistent) video
/// view there.
extension View {
    func playerPreviewSlot() -> some View {
        background(PlayerPreviewFrameProbe())
    }
}

private struct PlayerPreviewFrameProbe: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PlayerPreviewFrameReporter { frame in
            if model.player.previewFrameInWindow != frame { model.player.previewFrameInWindow = frame }
        }
        .allowsHitTesting(false)
        .onDisappear { model.player.previewFrameInWindow = nil }
    }
}

private struct PlayerPreviewFrameReporter: NSViewRepresentable {
    let onChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: FrameReportingView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    static func dismantleNSView(_ view: FrameReportingView, coordinator: ()) {
        view.stop()
        view.onChange?(nil)
    }

    /// Reports its frame in window-content coordinates (top-left origin) every display frame while it is
    /// in a window, so ancestor moves (sidebar animation, window resize, scrolling) are tracked.
    final class FrameReportingView: NSView {
        var onChange: ((CGRect?) -> Void)?
        private var link: CADisplayLink?
        private var last: CGRect?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if window != nil {
                let link = displayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                self.link = link
                report()
            } else {
                last = nil
                onChange?(nil)
            }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() { report() }

        func report() {
            guard let window, let content = window.contentView else { return }
            let r = convert(bounds, to: nil)
            let frame = CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height).integral
            guard frame != last else { return }
            last = frame
            onChange?(frame)
        }
    }
}
