#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

// Download controls shared by the movie and show pages, the in-player episode list and the Downloads section:
// the progress ring, the small status badge for artwork, the hero "Download" button, episode menu items, the
// offline banner and formatting.

// MARK: - State helpers

extension DownloadItem {
    /// Paused by the user (an automatic pause, while streaming on a one-connection account, resumes on its own).
    var isPausedByUser: Bool { state == .paused && pausedByUser }
    /// Queued, downloading, or paused automatically: on its way without the user doing anything.
    var isPending: Bool { state == .queued || state == .downloading || (state == .paused && !pausedByUser) }
}

// MARK: - Formatting

enum DownloadFormat {
    /// "Mac", "iPhone" or "iPad", for "1.2 GB on this iPhone".
    static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// "4.2 MB/s"
    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// Bytes the download occupies on disk (the whole file once complete, what's saved so far otherwise).
    static func sizeOnDisk(_ item: DownloadItem) -> Int64 {
        item.state == .completed ? max(item.receivedBytes, item.totalBytes ?? 0) : item.receivedBytes
    }

    /// "1.2 GB of 3.4 GB · 4.2 MB/s · 9 min left" (parts that aren't known yet are left out).
    static func progressLine(_ item: DownloadItem, speed: Double?) -> String {
        var parts: [String] = []
        if let total = item.totalBytes, total > 0 {
            parts.append("\(bytes(item.receivedBytes)) of \(bytes(total))")
        } else if item.receivedBytes > 0 {
            parts.append(bytes(item.receivedBytes))
        }
        if let speed, speed > 1024 {
            parts.append(Self.speed(speed))
            if let total = item.totalBytes, total > item.receivedBytes {
                parts.append(timeLeft(Double(total - item.receivedBytes) / speed))
            }
        }
        return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
    }

    /// "9 min left", "1 hr 5 min left", "Less than a minute left"
    static func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 60 { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min left" : "\(minutes) min left"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }
}

// MARK: - Progress ring

/// App Store–style circular progress: a faint track, the filled arc, and a stop square (downloading) or pause bars
/// (paused) in the middle. Without a known size it spins.
struct DownloadProgressRing: View {
    let item: DownloadItem
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.2
    var tint: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.28), lineWidth: lineWidth)
            if let fraction = item.fraction, item.state != .queued {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: fraction)
            } else if item.state == .downloading {
                DownloadSpinnerArc(tint: tint, lineWidth: lineWidth)
            }
            center
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var center: some View {
        switch item.state {
        case .downloading:
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(tint)
                .frame(width: size * 0.3, height: size * 0.3)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(tint)
        case .queued:
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint.opacity(0.8))
        case .completed, .failed:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch item.state {
        case .queued: "Download queued"
        case .downloading: item.fraction.map { "Downloading, \(DownloadFormat.percent($0))" } ?? "Downloading"
        case .paused: "Download paused"
        case .completed: "Downloaded"
        case .failed: "Download failed"
        }
    }
}

private struct DownloadSpinnerArc: View {
    let tint: Color
    let lineWidth: CGFloat
    @ViewState private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Status badge (artwork corner)

/// Small badge for episode cards and rows: a progress ring while queued/downloading/paused, a filled arrow when the
/// episode is on this Mac, an orange mark when the download failed. Nothing when there's no download.
struct DownloadStatusBadge: View {
    let item: DownloadItem?
    var size: CGFloat = 22

    var body: some View {
        if let item {
            Group {
                switch item.state {
                case .completed:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: size * 0.92))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .help("Downloaded")
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: size * 0.92))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .help(item.error?.nilIfEmpty ?? "Download failed")
                case .queued, .downloading, .paused:
                    DownloadProgressRing(item: item, size: size * 0.72, lineWidth: max(1.6, size * 0.09))
                        .frame(width: size, height: size)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .help(helpText(item))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 4)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func helpText(_ item: DownloadItem) -> String {
        switch item.state {
        case .queued: "Waiting to download"
        case .paused: "Download paused"
        default: item.fraction.map { "Downloading · \(DownloadFormat.percent($0))" } ?? "Downloading"
        }
    }
}

// MARK: - Movie page button

/// The movie hero's download control. "Download" (glass); while downloading a glass progress ring whose menu pauses,
/// resumes or cancels; once saved, "Downloaded" with Show in Finder and Delete Download.
struct MovieDownloadButton: View {
    @Environment(AppModel.self) private var model
    let movie: Movie
    var density: VODActionDensity = .full

    @ViewState private var confirmDelete = false

    private var item: DownloadItem? { model.downloadsById[movie.id] }
    private var iconOnly: Bool { density != .full }

    var body: some View {
        Group {
            if let item {
                switch item.state {
                case .completed: completedMenu(item)
                case .failed: failedMenu(item)
                case .queued, .downloading, .paused: progressMenu(item)
                }
            } else {
                VODSecondaryButton(title: "Download", systemImage: "arrow.down.circle", iconOnly: iconOnly) {
                    model.download(movie: movie)
                }
                .disabled(model.isOffline)
                .opacity(model.isOffline ? 0.5 : 1)
                .help(model.isOffline ? "You're offline" : "Download to watch offline")
            }
        }
        .confirmationDialog("Delete the download of “\(movie.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Download", role: .destructive) { model.deleteDownload(movie.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is removed from this Mac. You can still stream the movie or download it again.")
        }
        .animation(.smooth(duration: 0.25), value: item?.state)
    }

    private func progressMenu(_ item: DownloadItem) -> some View {
        Menu {
            if item.isPausedByUser {
                Button { model.resumeDownload(item.id) } label: { Label("Resume Download", systemImage: "arrow.down") }
            } else {
                Button { model.pauseDownload(item.id) } label: { Label("Pause Download", systemImage: "pause") }
            }
            Button { model.cancelDownload(item.id) } label: { Label("Cancel Download", systemImage: "xmark") }
            Divider()
            Button { model.sidebarSelection = .downloads } label: { Label("Show in Downloads", systemImage: "arrow.down.circle") }
        } label: {
            HStack(spacing: 8) {
                DownloadProgressRing(item: item, size: 18)
                if !iconOnly { Text(progressTitle(item)).monospacedDigit() }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassButtonStyle(circle: iconOnly))
        .fixedSize()
        .help(progressHelp(item))
    }

    private func completedMenu(_ item: DownloadItem) -> some View {
        Menu {
            Button { DownloadActions.reveal(item, model: model) } label: { Label("Show in Finder", systemImage: "folder") }
            Button { model.sidebarSelection = .downloads } label: { Label("Show in Downloads", systemImage: "arrow.down.circle") }
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Download…", systemImage: "trash") }
        } label: {
            if iconOnly {
                Image(systemName: "arrow.down.circle.fill")
            } else {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassButtonStyle(circle: iconOnly))
        .fixedSize()
        .help("Downloaded — plays from this Mac, even offline")
    }

    private func failedMenu(_ item: DownloadItem) -> some View {
        Menu {
            Button { model.resumeDownload(item.id) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            Button { model.cancelDownload(item.id) } label: { Label("Remove Download", systemImage: "xmark") }
        } label: {
            if iconOnly {
                Image(systemName: "exclamationmark.arrow.circlepath")
            } else {
                Label("Download Failed", systemImage: "exclamationmark.arrow.circlepath")
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GlassButtonStyle(circle: iconOnly))
        .fixedSize()
        .help(item.error?.nilIfEmpty ?? "The download didn't finish")
    }

    private func progressTitle(_ item: DownloadItem) -> String {
        switch item.state {
        case .queued: "Queued"
        case .paused: "Paused"
        default: item.fraction.map { "Downloading \(DownloadFormat.percent($0))" } ?? "Downloading"
        }
    }

    private func progressHelp(_ item: DownloadItem) -> String {
        switch item.state {
        case .queued:
            if model.downloadsSuspended { return "Waits until you stop watching (your account allows one stream)" }
            return item.error?.nilIfEmpty ?? "Waiting to download"
        case .paused: return item.pausedByUser ? "Paused" : "Paused while you watch"
        default: return DownloadFormat.progressLine(item, speed: model.downloadSpeeds[item.id])
        }
    }
}

// MARK: - Episode menu items

/// Download items for an episode's context menu: Download Episode, Pause/Resume, Cancel, Delete Download.
struct EpisodeDownloadMenuItems: View {
    @Environment(AppModel.self) private var model
    let episode: Episode
    let series: Series
    /// Asks before deleting a saved episode (deletes right away when nil).
    var confirmDelete: ((DownloadItem) -> Void)?

    var body: some View {
        if let item = model.downloadsById[episode.id] {
            switch item.state {
            case .queued, .downloading, .paused:
                if item.isPausedByUser {
                    Button { model.resumeDownload(item.id) } label: { Label("Resume Download", systemImage: "arrow.down") }
                } else {
                    Button { model.pauseDownload(item.id) } label: { Label("Pause Download", systemImage: "pause") }
                }
                Button { model.cancelDownload(item.id) } label: { Label("Cancel Download", systemImage: "xmark") }
            case .failed:
                Button { model.resumeDownload(item.id) } label: { Label("Try Download Again", systemImage: "arrow.clockwise") }
                Button { model.cancelDownload(item.id) } label: { Label("Remove Download", systemImage: "xmark") }
            case .completed:
                Button { DownloadActions.reveal(item, model: model) } label: { Label("Show in Finder", systemImage: "folder") }
                Button(role: .destructive) {
                    if let confirmDelete { confirmDelete(item) } else { model.deleteDownload(item.id) }
                } label: {
                    Label(confirmDelete == nil ? "Delete Download" : "Delete Download…", systemImage: "trash")
                }
            }
        } else {
            Button {
                model.download(episodes: [episode], of: series)
            } label: {
                Label("Download Episode", systemImage: "arrow.down.circle")
            }
            .disabled(model.isOffline)
        }
    }
}

// MARK: - Actions

@MainActor
enum DownloadActions {
    /// Selects the file in Finder (or opens the downloads folder while the file isn't there yet).
    static func reveal(_ item: DownloadItem, model: AppModel) {
        if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            revealFolder(model: model)
        }
    }

    static func revealFolder(model: AppModel) {
        let url = URL(fileURLWithPath: model.prefs.downloadsPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// Free space on the volume holding `path` (the nearest existing folder when it isn't created yet).
    nonisolated static func availableCapacity(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

// MARK: - Offline banner

/// Slim notice at the top of Home, Movies, TV Shows and Live TV while the Mac has no network.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isOffline {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("You're offline — your downloads are still available")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Button("Go to Downloads") { model.sidebarSelection = .downloads }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.25)))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}
