import SwiftUI
import TunerCore

/// Top of the Live TV screen: the player preview slot and details of the selected channel's programme.
struct LiveGuideHeader: View {
    @Environment(AppModel.self) private var model
    let store: LiveGuideStore

    @ViewState private var schedule: [Program] = []
    @ViewState private var scheduleKey: String?

    var body: some View {
        GeometryReader { geo in
            let availableHeight = max(120, geo.size.height - 36)
            let previewWidth = min(availableHeight * 16 / 9, geo.size.width * 0.52)
            HStack(alignment: .top, spacing: 28) {
                preview
                    .frame(width: previewWidth, height: previewWidth * 9 / 16)
                details(compact: geo.size.height < 250, roomy: geo.size.height >= 320)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .task(id: scheduleTaskKey) { await loadSchedule() }
    }

    // MARK: Preview slot

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            shape.fill(
                LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            if !model.player.hasMedia {
                VStack(spacing: 8) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Select a channel")
                        .font(.headline)
                    Text("Click a channel in the guide to preview it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .transition(.opacity)
            }
            // The app's PlayerHost draws the live video exactly over this frame.
            Color.clear.playerPreviewSlot()
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .animation(.easeOut(duration: 0.25), value: model.player.hasMedia)
    }

    // MARK: Details

    @ViewBuilder
    private func details(compact: Bool, roomy: Bool) -> some View {
        if let channel = store.selectedChannel {
            channelDetails(channel, compact: compact, roomy: roomy)
                .id(channel.id)
                .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.title(for: model.liveScope, model: model))
                    .font(.largeTitle.weight(.bold))
                Text("Choose a channel in the guide to preview it. Double-click, or press Return, to watch full screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    /// `compact` (minimum header height) drops the subtitle and description so the actions always fit.
    private func channelDetails(_ channel: Channel, compact: Bool, roomy: Bool) -> some View {
        let now = store.now
        let scheduleLoaded = scheduleKey == channel.epgKey
        let list = scheduleLoaded ? schedule : []
        let current = list.first { $0.isLive(at: now) }
        let next = list.first { $0.start >= (current?.end ?? now) }
        let mainItem = model.player.main.item
        let isPlayingLive = mainItem?.isLive == true && mainItem?.channel?.id == channel.id
        let isPlayingCatchup = mainItem?.isLive == false && mainItem?.channel?.id == channel.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ChannelLogo(url: channel.logoURL, name: channel.displayName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(channel.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        if isPlayingLive {
                            LiveGuideBadge(text: "LIVE", color: .red)
                        } else if isPlayingCatchup {
                            LiveGuideBadge(text: "CATCH UP", color: .accentColor)
                        }
                    }
                    if let subtitle = channelSubtitle(channel) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.bottom, compact ? 8 : 12)

            if let current {
                Text(current.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(compact ? 1 : 2)
                if !compact, let sub = current.subtitle?.nilIfEmpty ?? current.episode?.nilIfEmpty {
                    Text(sub)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    Text(Fmt.timeRange(current.start, current.end))
                    Text("·")
                    Text(Fmt.remaining(until: current.end, now: now))
                }
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                ProgressCapsule(fraction: current.progress(at: now))
                    .frame(maxWidth: 300)
                    .padding(.top, 8)
                if !compact, let summary = current.summary?.nilIfEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(roomy ? 3 : 2)
                        .padding(.top, 10)
                        .layoutPriority(-1)
                }
            } else {
                Text(channel.displayName)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Text(scheduleLoaded || channel.epgKey == nil ? "No guide information" : " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            if let next {
                HStack(spacing: 5) {
                    Text("Up Next")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(Fmt.time(next.start))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .lineLimit(1)
                }
                .font(.callout)
                .padding(.top, 10)
                .layoutPriority(-1)
            }

            Spacer(minLength: 10)
            actions(channel)
        }
    }

    private func actions(_ channel: Channel) -> some View {
        let favorite = store.isFavorite(channel)
        let recording = model.isRecording(channel)
        return HStack(spacing: 10) {
            Button {
                store.select(channel)
                model.play(channel, fullWindow: true)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle())
            .hoverLift(scale: 1.03)

            Button { store.toggleFavorite(channel) } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? Color.yellow : Color.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(GlassButtonStyle(circle: true))
            .help(favorite ? "Remove from Favorites" : "Add to Favorites")

            Button { model.recordNow(channel) } label: {
                Image(systemName: recording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recording ? Color.red : Color.white)
            }
            .buttonStyle(GlassButtonStyle(circle: true))
            .disabled(recording)
            .help(recording ? "Recording" : "Record Now")

            Menu {
                LiveGuideChannelMenu(channel: channel, store: store, includePlayback: false)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 40, height: 40)
            .background(Circle().fill(.white.opacity(0.16)))
            .help("More")
        }
        .fixedSize()
    }

    private func channelSubtitle(_ channel: Channel) -> String? {
        var parts: [String] = []
        if let n = channel.number { parts.append("Channel \(n)") }
        if let cid = channel.categoryId, let cat = store.categories.first(where: { $0.id == cid }) {
            parts.append(cat.displayName)
        }
        if model.sources.count > 1, let source = model.sources.first(where: { $0.id == channel.sourceId }) {
            parts.append(source.name)
        }
        if channel.hasCatchup { parts.append("Catch Up") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Loading

    private var scheduleTaskKey: LiveHeaderScheduleKey {
        LiveHeaderScheduleKey(
            epgKey: store.selectedChannel?.epgKey,
            revision: model.guideRevision,
            // Refetch every two hours so "Up Next" never runs off the loaded range.
            bucket: Int(store.now.timeIntervalSince1970 / 7200)
        )
    }

    private func loadSchedule() async {
        guard let key = store.selectedChannel?.epgKey else {
            schedule = []
            scheduleKey = nil
            return
        }
        let now = Date()
        let map = (try? await model.db.programs(epgKeys: [key], from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(12 * 3600))) ?? [:]
        guard !Task.isCancelled else { return }
        schedule = map[key] ?? []
        scheduleKey = key
    }
}

private struct LiveHeaderScheduleKey: Hashable {
    var epgKey: String?
    var revision: Int
    var bucket: Int
}

/// Small capsule label ("LIVE", "CATCH UP").
struct LiveGuideBadge: View {
    let text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}
