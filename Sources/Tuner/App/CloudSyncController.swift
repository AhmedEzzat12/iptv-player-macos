#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
import TunerCore

/// iCloud sync for the app (Settings → Sync): the folder, when passes run, and the status shown in Settings.
/// The work itself happens in `CloudSyncEngine` (TunerCore), off the main actor.
///
/// Passes run at launch (once the library is loaded), when the app becomes active, every 2 minutes while it is,
/// a few seconds after user-state or preference changes (a minute for watch progress, which is saved every few
/// seconds during playback), and on "Sync Now".
@MainActor
@Observable
final class CloudSyncController {
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { syncNow() } else { cancelScheduled() }
        }
    }
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var notices: [String] = []
    /// Other devices found in the folder.
    private(set) var peers: [CloudSyncPeer] = []
    /// Mac: the chosen folder's path. iPhone/iPad: the chosen folder's name. Nil until there is one.
    private(set) var folderDescription: String?
    /// iPhone/iPad: no folder chosen yet, or its bookmark no longer resolves.
    private(set) var needsFolder = false
    /// TUNER_SYNC_DIR (or `-TunerSyncDir` in iOS debug builds): a plain folder for testing; turns sync on.
    let debugFolder: URL?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let engine: CloudSyncEngine
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var scheduledFor: Date?
    @ObservationIgnored private var runAgain = false
    /// Changes caused by applying other devices' data are ignored until then (they'd only trigger an empty pass).
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let enabledKey = "cloudSyncEnabled"
    static let folderPathKey = "cloudSyncFolderPath"
    static let folderBookmarkKey = "cloudSyncFolderBookmark"
    static let deviceIdKey = "cloudSyncDeviceId"
    static let interval: Duration = .seconds(120)

    init(db: AppDatabase, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        debugFolder = Self.debugFolderOverride(defaults)
        isEnabled = debugFolder != nil || defaults.bool(forKey: Self.enabledKey)
        let deviceId: String
        if let stored = defaults.string(forKey: Self.deviceIdKey) {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: Self.deviceIdKey)
        }
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        engine = CloudSyncEngine(db: db, device: .init(id: deviceId, name: Self.deviceName, platform: platform, appVersion: version))
        refreshFolderDescription()
    }

    private static func debugFolderOverride(_ defaults: UserDefaults) -> URL? {
        #if DEBUG && os(iOS)
        let path = ProcessInfo.processInfo.environment["TUNER_SYNC_DIR"] ?? defaults.string(forKey: "TunerSyncDir")
        #else
        let path = ProcessInfo.processInfo.environment["TUNER_SYNC_DIR"]
        #endif
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    // MARK: - Triggers

    /// Called once the library has loaded.
    func start(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Watch progress is saved every few seconds while playing: wait a minute; anything else, a few seconds.
        observe(["watchProgress"], delay: 60)
        observe(["channelPref", "categoryPref", "vodFavorite", "history", "customGroup", "customGroupMember", "source"], delay: 3)
        trackPreferences()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                if self.isEnabled, Self.appIsActive { await self.run() }
            }
        })
        #if os(macOS)
        let active = NSApplication.didBecomeActiveNotification
        let inactive = NSApplication.didResignActiveNotification
        #else
        let active = UIApplication.didBecomeActiveNotification
        let inactive = UIApplication.didEnterBackgroundNotification
        #endif
        observers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(in: 1) }
        })
        // Leaving the app: publish pending changes (e.g. where playback stopped) right away.
        observers.append(NotificationCenter.default.addObserver(forName: inactive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scheduledFor != nil else { return }
                self.schedule(in: 0)
            }
        })
        if isEnabled { syncNow() }
    }

    func syncNow() {
        guard isEnabled else { return }
        schedule(in: 0)
    }

    private static var appIsActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Runs a pass after `seconds`, unless one is already due sooner.
    private func schedule(in seconds: Double) {
        guard isEnabled else { return }
        let due = Date().addingTimeInterval(seconds)
        if let current = scheduledFor, current <= due { return }
        scheduled?.cancel()
        scheduledFor = due
        scheduled = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, let self else { return }
            self.scheduledFor = nil
            await self.run()
        }
    }

    private func cancelScheduled() {
        scheduled?.cancel()
        scheduled = nil
        scheduledFor = nil
    }

    private func observe(_ tables: [String], delay: Double) {
        tasks.append(Task { [weak self] in
            guard let stream = self?.model?.db.changes(in: tables) else { return }
            for await _ in stream {
                guard let self else { return }
                if Date() >= self.quietUntil { self.schedule(in: delay) }
            }
        })
    }

    private func trackPreferences() {
        guard let prefs = model?.prefs else { return }
        withObservationTracking {
            _ = prefs.cloudSyncValues()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date() >= self.quietUntil { self.schedule(in: 3) }
                self.trackPreferences()
            }
        }
    }

    // MARK: - Pass

    private func run() async {
        guard isEnabled, let model else { return }
        guard !isSyncing else {
            runAgain = true
            return
        }
        // Never while a playlist is being edited: the import could change the playlist under the editor.
        guard model.openSourceEditors == 0 else {
            schedule(in: 5)
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let folder: URL
        let endAccess: () -> Void
        switch resolveFolder() {
        case .success(let access):
            (folder, endAccess) = access
        case .failure(let error):
            lastError = error.message
            return
        }
        let report = await engine.sync(folder: folder, preferences: model.prefs.cloudSyncValues())
        endAccess()

        if report.appliedCount > 0 || !report.preferences.isEmpty { quietUntil = Date().addingTimeInterval(2) }
        if !report.preferences.isEmpty {
            model.prefs.applyCloudSync(report.preferences)
            await model.applyPreferences()
        }
        for id in report.readySourceIds { model.sync(id) }
        if report.sourcesNeedingPassword > 0 {
            let many = report.sourcesNeedingPassword > 1
            model.notify(Banner(symbol: "key.fill",
                                title: many ? "Playlists added from another device" : "Playlist added from another device",
                                message: "Enter \(many ? "their passwords" : "its password") in Settings → Playlists to turn \(many ? "them" : "it") on."))
        }
        lastError = report.error
        notices = report.notices
        peers = report.peers.sorted { $0.exportedAt > $1.exportedAt }
        if report.error == nil { lastSync = report.finishedAt }

        if runAgain {
            runAgain = false
            schedule(in: 1)
        }
    }

    // MARK: - Folder

    struct FolderError: Error {
        var message: String
    }

    private func resolveFolder() -> Result<(URL, () -> Void), FolderError> {
        if let debugFolder {
            try? FileManager.default.createDirectory(at: debugFolder, withIntermediateDirectories: true)
            return .success((debugFolder, {}))
        }
        #if os(macOS)
        let url = macFolder
        if defaults.string(forKey: Self.folderPathKey) == nil {
            // The default folder in iCloud Drive: created when iCloud Drive is on.
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
                return .failure(FolderError(message: "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings, or choose another folder."))
            }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return .success((url, {}))
        #else
        guard let data = defaults.data(forKey: Self.folderBookmarkKey) else {
            needsFolder = true
            return .failure(FolderError(message: "Choose the sync folder in iCloud Drive."))
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            needsFolder = true
            return .failure(FolderError(message: "The sync folder can't be found any more. Choose it again."))
        }
        let accessing = url.startAccessingSecurityScopedResource()
        if stale {
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.folderBookmarkKey)
            } else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                needsFolder = true
                return .failure(FolderError(message: "Tuner lost access to the sync folder. Choose it again."))
            }
        }
        needsFolder = false
        return .success((url, { if accessing { url.stopAccessingSecurityScopedResource() } }))
        #endif
    }

    #if os(macOS)
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Tuner Sync` unless the user chose another folder. A scratch
    /// library (TUNER_DATA_DIR) keeps its default inside the scratch folder, so test copies never touch iCloud Drive.
    var macFolder: URL {
        if let path = defaults.string(forKey: Self.folderPathKey) { return URL(fileURLWithPath: path, isDirectory: true) }
        return Self.defaultMacFolder
    }

    static var defaultMacFolder: URL {
        if let scratch = TunerApp.dataDirectoryOverride { return scratch.appendingPathComponent("Sync", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Tuner Sync", isDirectory: true)
    }

    var usesDefaultFolder: Bool { defaults.string(forKey: Self.folderPathKey) == nil }

    /// A folder picked with the open panel; nil goes back to the default one.
    func chooseFolder(_ url: URL?) {
        if let url { defaults.set(url.path, forKey: Self.folderPathKey) } else { defaults.removeObject(forKey: Self.folderPathKey) }
        folderChanged()
    }
    #else
    /// A folder picked with the Files picker: kept as a bookmark and opened again for every pass.
    func chooseFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: Self.folderBookmarkKey)
            needsFolder = false
            folderChanged()
        } catch {
            lastError = "Couldn't keep access to that folder: \(error.localizedDescription)"
        }
    }
    #endif

    private func folderChanged() {
        refreshFolderDescription()
        peers = []
        notices = []
        lastError = nil
        syncNow()
    }

    private func refreshFolderDescription() {
        if let debugFolder {
            folderDescription = debugFolder.path
            return
        }
        #if os(macOS)
        folderDescription = macFolder.path
        #else
        guard let data = defaults.data(forKey: Self.folderBookmarkKey) else {
            folderDescription = nil
            needsFolder = true
            return
        }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        folderDescription = url?.lastPathComponent
        needsFolder = url == nil
        #endif
    }
}
