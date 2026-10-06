#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

/// DVR library, Apple TV app style: recording now, scheduled, recorded, and problems.
struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var files: [String: RecordingsFileInfo] = [:]
    @ViewState private var logos: [String: String] = [:]
    @ViewState private var pendingDelete: Recording?
    @ViewState private var ffmpegMissing = RecordingService.ffmpegPath() == nil

    var body: some View {
        let groups = RecordingsGroups(model.recordings)
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Text("Recordings")
                        .font(.largeTitle.weight(.bold))

                    if ffmpegMissing {
                        RecordingsFFmpegNotice()
                    }

                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No Recordings",
                            systemImage: "record.circle",
                            description: Text("Record a live programme from the guide or the player, or schedule one from a programme's menu.")
                        )
                        .frame(maxWidth: .infinity, minHeight: max(320, proxy.size.height - 260))
                    } else {
                        if !groups.active.isEmpty { activeSection(groups.active) }
                        if !groups.scheduled.isEmpty { scheduledSection(groups.scheduled) }
                        if !groups.completed.isEmpty { recordedSection(groups.completed) }
                        if !groups.problems.isEmpty { problemsSection(groups.problems) }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Keyed on the recordings themselves: `userRevision` bumps before `recordings` reloads.
        .task(id: model.recordings) { await loadDetails() }
        .onAppear { ffmpegMissing = RecordingService.ffmpegPath() == nil }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { recording in
            Button("Move to Trash", role: .destructive) { model.deleteRecording(recording, deleteFile: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording is removed from Tuner and its file is moved to the Trash.")
        }
    }

    // MARK: Sections

    private func activeSection(_ items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Recording Now")
            VStack(spacing: 12) {
                ForEach(items) { recording in
                    RecordingsActiveRow(recording: recording, logoURL: logos[recording.channelId]) {
                        model.cancelRecording(recording)
                    }
                }
            }
        }
    }

    private func scheduledSection(_ items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Scheduled", subtitle: items.count > 1 ? "\(items.count) recordings" : nil)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, recording in
                    if index > 0 { Divider().padding(.leading, 20) }
                    RecordingsScheduledRow(recording: recording, logoURL: logos[recording.channelId]) {
                        model.cancelRecording(recording)
                    }
                }
            }
            .recordingsPlatter()
        }
    }

    private func recordedSection(_ items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Recorded", subtitle: totalSizeText(items))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 22, alignment: .top)],
                      alignment: .leading, spacing: 28) {
                ForEach(items) { recording in
                    RecordingsCard(
                        recording: recording,
                        file: files[recording.id],
                        logoURL: logos[recording.channelId],
                        onPlay: { model.play(recording: recording) },
                        onReveal: { reveal(recording) },
                        onDelete: { pendingDelete = recording }
                    )
                }
            }
        }
    }

    private func problemsSection(_ items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Failed & Cancelled")
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, recording in
                    if index > 0 { Divider().padding(.leading, 20) }
                    RecordingsProblemRow(
                        recording: recording,
                        hasFile: files[recording.id]?.exists == true,
                        onReveal: { reveal(recording) },
                        onRemove: { model.deleteRecording(recording, deleteFile: false) }
                    )
                }
            }
            .recordingsPlatter()
        }
    }

    // MARK: Helpers

    private func totalSizeText(_ items: [Recording]) -> String? {
        let total = items.compactMap { files[$0.id]?.size }.reduce(0, +)
        guard total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func reveal(_ recording: Recording) {
        guard let path = recording.filePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// File sizes / existence and channel logos for the current recordings.
    private func loadDetails() async {
        let recordings = model.recordings
        let paths = recordings.compactMap { r in r.filePath.map { (r.id, $0) } }
        files = await Task.detached(priority: .utility) {
            var result: [String: RecordingsFileInfo] = [:]
            for (id, path) in paths {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                result[id] = RecordingsFileInfo(exists: attrs != nil, size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return result
        }.value

        var found = logos
        for channelId in Set(recordings.map(\.channelId)) where found[channelId] == nil {
            if let logo = try? await model.db.channel(id: channelId)?.logoURL {
                found[channelId] = logo
            }
        }
        if found != logos { logos = found }
    }
}

extension View {
    /// Subtle rounded platter for content rows (Liquid Glass is reserved for floating controls).
    func recordingsPlatter(cornerRadius: CGFloat = 18) -> some View {
        background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct RecordingsFileInfo: Equatable, Sendable {
    var exists: Bool
    var size: Int64
}

private struct RecordingsGroups {
    var active: [Recording] = []
    var scheduled: [Recording] = []
    var completed: [Recording] = []
    var problems: [Recording] = []

    init(_ recordings: [Recording]) {
        for r in recordings {
            switch r.status {
            case .recording: active.append(r)
            case .scheduled: scheduled.append(r)
            case .completed: completed.append(r)
            case .failed, .cancelled: problems.append(r)
            }
        }
        active.sort { $0.start < $1.start }
        scheduled.sort { $0.start < $1.start }
        completed.sort { $0.start > $1.start }
        problems.sort { $0.start > $1.start }
    }

    var isEmpty: Bool { active.isEmpty && scheduled.isEmpty && completed.isEmpty && problems.isEmpty }
}

// MARK: - ffmpeg notice

private struct RecordingsFFmpegNotice: View {
    @ViewState private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recording needs ffmpeg").font(.headline)
                (Text("Install it with Homebrew, then come back: ") + Text("brew install ffmpeg").font(.callout.monospaced()))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(copied ? "Copied" : "Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .recordingsPlatter()
    }
}

// MARK: - Recording now

private struct RecordingsActiveRow: View {
    let recording: Recording
    let logoURL: String?
    let onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let now = context.date
            let total = max(1, recording.end.timeIntervalSince(recording.start))
            let fraction = now.timeIntervalSince(recording.start) / total

            HStack(spacing: 18) {
                ChannelLogo(url: logoURL, name: recording.channelName, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("REC")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.red)
                        Text(recording.channelName)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(recording.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        ProgressCapsule(fraction: fraction, height: 5, tint: .red)
                            .frame(maxWidth: 360)
                        Text("\(Fmt.timeRange(recording.start, recording.end)) · \(Fmt.remaining(until: recording.end, now: now))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .help("Stop recording and keep what's been recorded")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .recordingsPlatter()
        }
    }
}

// MARK: - Scheduled

private struct RecordingsScheduledRow: View {
    let recording: Recording
    let logoURL: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.day(recording.start))
                    .font(.callout.weight(.semibold))
                Text(Fmt.timeRange(recording.start, recording.end))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 150, alignment: .leading)

            ChannelLogo(url: logoURL, name: recording.channelName, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(recording.channelName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help("Cancel this scheduled recording")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contextMenu {
            Button("Cancel Recording", role: .destructive, action: onCancel)
        }
    }
}

// MARK: - Recorded

private struct RecordingsCard: View {
    let recording: Recording
    let file: RecordingsFileInfo?
    let logoURL: String?
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    @ViewState private var hovering = false

    private var isMissing: Bool { recording.filePath == nil || file?.exists == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onPlay) {
                artwork
            }
            .buttonStyle(.plain)
            .disabled(isMissing)
            .hoverLift(scale: 1.03)
            .onHover { hovering = $0 }
            .help(isMissing ? "The recording file is missing" : "Play")

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(recording.channelName) · \(Fmt.day(recording.start)), \(Fmt.time(recording.start))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(isMissing ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contextMenu {
            Button("Play", action: onPlay).disabled(isMissing)
            Button("Show in Finder", action: onReveal).disabled(isMissing)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private var detailText: String {
        if isMissing { return "File missing" }
        var parts = [Fmt.duration(recording.end.timeIntervalSince(recording.start))]
        if let size = file?.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private var artwork: some View {
        let hue = Self.hue(for: recording.title)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                         Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            Text(recording.title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .padding(14)
        }
        .overlay(alignment: .topLeading) {
            if logoURL != nil {
                ChannelLogo(url: logoURL, name: recording.channelName, size: 24)
                    .padding(10)
            }
        }
        .overlay {
            if hovering, !isMissing {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .opacity(isMissing ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Stable per-title hue (Swift's `hashValue` changes between launches).
    static func hue(for title: String) -> Double {
        let sum = title.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return Double(sum % 360) / 360
    }
}

// MARK: - Failed & cancelled

private struct RecordingsProblemRow: View {
    let recording: Recording
    let hasFile: Bool
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: recording.status == .failed ? "exclamationmark.triangle" : "xmark.circle")
                .font(.title3)
                .foregroundStyle(recording.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(recording.channelName) · \(Fmt.day(recording.start)), \(Fmt.timeRange(recording.start, recording.end))")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(recording.status == .failed ? AnyShapeStyle(.orange.opacity(0.85)) : AnyShapeStyle(.tertiary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if hasFile {
                Button("Show in Finder", action: onReveal)
                    .buttonStyle(.borderless)
            }
            Button("Remove", action: onRemove)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help("Remove from the list (any partial file is kept)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contextMenu {
            if hasFile { Button("Show in Finder", action: onReveal) }
            Button("Remove", action: onRemove)
        }
    }

    private var reason: String {
        if let error = recording.error, !error.isEmpty { return error }
        return recording.status == .cancelled ? "Cancelled" : "Failed"
    }
}
