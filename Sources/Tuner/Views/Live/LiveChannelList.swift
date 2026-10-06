import SwiftUI
import TunerCore

/// Narrow layouts (iPhone): channels as a vertical list with what's on now and next, instead of the timeline grid.
/// Tapping a channel watches it full screen; the context menu is the guide's channel menu.
struct LiveChannelList: View {
    let store: LiveGuideStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.channels, id: \.id) { channel in
                    LiveChannelListRow(channel: channel, store: store)
                }
            }
            .padding(.horizontal, VODMetrics.inset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct LiveChannelListRow: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let store: LiveGuideStore

    var body: some View {
        let isPlaying = model.player.main.item?.channel?.id == channel.id
        let (current, next) = schedule
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if model.prefs.showChannelNumbers, let number = channel.number {
                        Text("\(number)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(channel.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if store.isFavorite(channel) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if channel.hasCatchup {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let current {
                    Text(current.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: progress(of: current))
                        .progressViewStyle(.linear)
                        .tint(isPlaying ? Color.accentColor : .secondary)
                        .frame(maxWidth: 160)
                    if let next {
                        Text("Next · \(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else if store.isLoaded(channel) {
                    Text("No guide information")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: model.player.main.isPlaying)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isPlaying ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { model.play(channel, fullWindow: true) }
        .contextMenu { LiveGuideChannelMenu(channel: channel, store: store) }
        .onAppear { store.rowAppeared(channel.epgKey) }
        .onDisappear { store.rowDisappeared(channel.epgKey) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.play(channel, fullWindow: true) }
    }

    /// The programme on now and the one after it, from the guide window the store has loaded.
    private var schedule: (Program?, Program?) {
        guard let programs = store.programs(for: channel), !programs.isEmpty else { return (nil, nil) }
        let now = store.now
        guard let index = programs.firstIndex(where: { $0.start <= now && $0.end > now }) else {
            return (nil, programs.first { $0.start > now })
        }
        return (programs[index], index + 1 < programs.count ? programs[index + 1] : nil)
    }

    private func progress(of program: Program) -> Double {
        let total = program.end.timeIntervalSince(program.start)
        guard total > 0 else { return 0 }
        return min(max(store.now.timeIntervalSince(program.start) / total, 0), 1)
    }
}
