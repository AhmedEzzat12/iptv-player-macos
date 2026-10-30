import SwiftUI
import TunerCore

/// Netflix-style "Skip Intro" / "Skip Credits" capsule, bottom-trailing above the controls (see `SkipController`).
struct PlayerSkipButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact
    let segment: SkipSegment

    var body: some View {
        Button {
            model.skip.skipCurrent()
        } label: {
            Label(segment.buttonTitle, systemImage: segment.kind == .credits ? "forward.end.fill" : "forward.fill")
                .labelStyle(PlayerSkipLabelStyle())
                .font((compact ? Font.callout : .body).weight(.semibold))
                .padding(.horizontal, compact ? 16 : 22)
                .frame(height: compact ? 40 : 46)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.25), in: Capsule())
                .playerGlass(in: Capsule(), interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(segment.buttonTitle)
    }

    private var helpText: String {
        #if os(macOS)
        let key = model.prefs.key(for: .skipSegment)
        return key.isEmpty ? segment.buttonTitle : "\(segment.buttonTitle) (\(ShortcutKey.label(key)))"
        #else
        segment.buttonTitle
        #endif
    }
}

/// "Skipped intro · Undo", shown for a few seconds after an automatic skip.
struct PlayerSkipNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tunerCompact) private var compact
    let segment: SkipSegment

    var body: some View {
        HStack(spacing: 12) {
            Label(segment.skippedTitle, systemImage: "forward.fill")
                .labelStyle(PlayerSkipLabelStyle())
            Button("Undo") { model.skip.undo() }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: compact ? 28 : 30)
                .foregroundStyle(.black)
                .background(Color.white, in: Capsule())
                .contentShape(Capsule())
        }
        .font((compact ? Font.callout : .body).weight(.semibold))
        .foregroundStyle(.white)
        .padding(.leading, compact ? 16 : 20)
        .padding(.trailing, 7)
        .frame(height: compact ? 40 : 46)
        .background(Color.black.opacity(0.25), in: Capsule())
        .playerGlass(in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// Title first, glyph after it ("Skip Intro ▶▶").
private struct PlayerSkipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon.font(.system(size: 13, weight: .bold))
        }
    }
}
