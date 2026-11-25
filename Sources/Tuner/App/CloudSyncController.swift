#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Observation
#if os(iOS)
import Security
#endif
import TunerCore

/// iCloud sync for the app (Settings → Sync): the folder, when passes run, and the status shown in Settings.
/// The work itself happens in `CloudSyncEngine` (TunerCore), off the main actor.
///
/// Passes run at launch (once the library is loaded), when the app becomes active, every 2 minutes (the Mac also in the
/// background; iPhone/iPad only while active),
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
    /// Playlists sync with their passwords and full links, so other devices turn them on by themselves.
    var includePasswords: Bool {
        didSet {
            guard includePasswords != oldValue else { return }
            defaults.set(includePasswords, forKey: Self.passwordsKey)
            syncNow()
        }
    }
    /// This device's name in the other devices' lists (defaults to the computer or device name).
    private(set) var deviceName: String
    /// This device's sync id (shown nowhere; kept across reinstalls on iPhone/iPad, see `loadDeviceId`).
    private(set) var deviceId: String

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
    static let deviceNameKey = "cloudSyncDeviceName"
    static let passwordsKey = "cloudSyncPasswords"
    static let removedKey = "cloudSyncRemovedDevices"
    static let trustedKeysKey = "cloudSyncTrustedKeys"
    static let interval: Duration = .seconds(120)

    init(db: AppDatabase, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        debugFolder = Self.debugFolderOverride(defaults)
        isEnabled = debugFolder != nil || defaults.bool(forKey: Self.enabledKey)
        includePasswords = defaults.object(forKey: Self.passwordsKey) as? Bool ?? true
        trustedKeys = defaults.dictionary(forKey: Self.trustedKeysKey) as? [String: String] ?? [:]
        let deviceId = Self.loadDeviceId(defaults)
        self.deviceId = deviceId
        let name = defaults.string(forKey: Self.deviceNameKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.systemDeviceName
        deviceName = name
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let key = Self.loadKey()
        keyUnavailable = key == nil
        engine = CloudSyncEngine(db: db, device: .init(id: deviceId, name: name, platform: platform, appVersion: version),
                                 key: key ?? .init())
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

    static var systemDeviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    // MARK: - This device

    /// The sync id. On iPhone/iPad it lives in the Keychain, which survives deleting the app (UserDefaults doesn't), so a
    /// reinstall keeps writing the same file instead of showing up as a new device. Ids saved by earlier versions in
    /// UserDefaults move to the Keychain. On the Mac, UserDefaults already survive reinstalling.
    private static func loadDeviceId(_ defaults: UserDefaults) -> String {
        #if os(iOS)
        let lookup = SyncKeychain.lookup("deviceId")
        if case .found(let data) = lookup, let id = String(data: data, encoding: .utf8) {
            defaults.set(id, forKey: deviceIdKey)
            return id
        }
        let id = defaults.string(forKey: deviceIdKey) ?? UUID().uuidString
        // Only when the Keychain really has none (not when it's locked): a write then could replace the saved id.
        if case .notFound = lookup { SyncKeychain.write("deviceId", Data(id.utf8)) }
        defaults.set(id, forKey: deviceIdKey)
        return id
        #else
        if let id = defaults.string(forKey: deviceIdKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIdKey)
        return id
        #endif
    }

    private func newDeviceId() {
        let id = UUID().uuidString
        deviceId = id
        defaults.set(id, forKey: Self.deviceIdKey)
        #if os(iOS)
        SyncKeychain.write("deviceId", Data(id.utf8))
        #endif
        Task { await engine.setDeviceId(id) }
    }

    /// The private key that opens passwords other devices sealed for this one (`CloudSyncSecrets`). It never leaves
    /// the device: iPhone/iPad keep it in the Keychain (surviving reinstalls, like the device id); the Mac in a file only
    /// this user can read, next to the library.
    ///
    /// iPhone/iPad: a new key is made only when the Keychain has none. Before the first unlock after a restart (the app
    /// can start then, for background audio) the Keychain refuses reads; treating that as "no key" replaced the real key,
    /// and the other devices, which pin each device's key, stopped sealing passwords for it. Nil means "not readable
    /// now": passes wait until it is (`ensureKey`).
    private static func loadKey() -> CloudSyncSecrets.PrivateKey? {
        #if os(iOS)
        switch SyncKeychain.lookup("privateKey") {
        case .found(let data):
            if let key = try? CloudSyncSecrets.PrivateKey(rawRepresentation: data) { return key }
            return storeNewKey()
        case .notFound:
            return storeNewKey()
        case .unavailable:
            return nil
        }
        #else
        let url = TunerApp.dataDirectory.appendingPathComponent("sync-key")
        if let data = try? Data(contentsOf: url), let key = try? CloudSyncSecrets.PrivateKey(rawRepresentation: data) { return key }
        return storeNewKey()
        #endif
    }

    private static func storeNewKey() -> CloudSyncSecrets.PrivateKey {
        let key = CloudSyncSecrets.PrivateKey()
        #if os(iOS)
        SyncKeychain.write("privateKey", key.rawRepresentation)
        #else
        let url = TunerApp.dataDirectory.appendingPathComponent("sync-key")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
        #endif
        return key
    }

    /// The key couldn't be read at launch (iPhone/iPad, before the first unlock): no pass runs until it can, because
    /// publishing a stand-in key would make the other devices stop sending passwords.
    @ObservationIgnored private var keyUnavailable = false

    private func ensureKey() async -> Bool {
        guard keyUnavailable else { return true }
        guard let key = Self.loadKey() else { return false }
        keyUnavailable = false
        try? await engine.reset(id: deviceId, key: key, folder: nil)
        return true
    }

    /// Settings → Sync → Reset Sync: this device starts over as a new one. Its file leaves the folder, it gets a new id
    /// and key, forgets the keys it pinned for the other devices and what it last published, then syncs: the other
    /// devices' playlists, passwords, progress and settings are applied again (theirs win over this device's, as on a
    /// first sync), and they seal passwords for the new key on their next pass. Removed devices stay removed.
    func resetSync() async {
        cancelScheduled()
        let folder: (URL, () -> Void)? = try? resolveFolder().get()
        let id = UUID().uuidString
        deviceId = id
        defaults.set(id, forKey: Self.deviceIdKey)
        #if os(iOS)
        SyncKeychain.write("deviceId", Data(id.utf8))
        #endif
        let key = Self.storeNewKey()
        keyUnavailable = false
        trustedKeys = [:]
        try? await engine.reset(id: id, key: key, folder: folder?.0)
        folder?.1()
        peers = []
        notices = []
        lastError = nil
        lastSync = nil
        syncNow()
    }

    /// Renames this device for the other devices' lists; an empty name goes back to the system name.
    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.deviceNameKey) } else { defaults.set(trimmed, forKey: Self.deviceNameKey) }
        let resolved = trimmed.isEmpty ? Self.systemDeviceName : trimmed
        guard resolved != deviceName else { return }
        deviceName = resolved
        Task {
            await engine.setDeviceName(resolved)
            syncNow()
        }
    }

    // MARK: - Other devices

    private var removedDevices: [String: Int64] {
        get { (defaults.dictionary(forKey: Self.removedKey) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:] }
        set { defaults.set(newValue.mapValues { NSNumber(value: $0) }, forKey: Self.removedKey) }
    }

    /// Other devices' keys as first seen (device id → base64 public key). Every device in the folder gets passwords;
    /// one whose key changed since gets nothing until "Trust Again".
    private(set) var trustedKeys: [String: String] = [:] {
        didSet { defaults.set(trustedKeys, forKey: Self.trustedKeysKey) }
    }

    /// A known device that now shows another key (a file someone else wrote, or a reinstall that lost its key).
    func keyChanged(_ peer: CloudSyncPeer) -> Bool {
        guard let key = peer.publicKey, let pinned = trustedKeys[peer.id] else { return false }
        return key != pinned
    }

    /// Accepts a device's new key (only if it's really still one of your devices).
    func trustAgain(_ peer: CloudSyncPeer) {
        guard let key = peer.publicKey else { return }
        trustedKeys[peer.id] = key
        syncNow()
    }

    /// Removes a device from sync: its file is deleted on the next pass, and the removal travels in this device's file,
    /// so the removed device turns sync off when it next runs (and a stale file from it is deleted wherever it turns up).
    func removeDevice(_ peer: CloudSyncPeer) {
        var removed = removedDevices
        removed[peer.id] = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        removedDevices = removed
        trustedKeys[peer.id] = nil
        peers.removeAll { $0.id == peer.id }
        syncNow()
    }

    /// Another device removed this one: sync turns off, and turning it on again joins as a new device.
    private func removedByAnotherDevice() async {
        isEnabled = false
        newDeviceId()
        peers = []
        try? await model?.db.resetCloudSyncLedger()
        model?.notify(Banner(symbol: "icloud.slash", title: "Removed from sync",
                             message: "This device was removed from sync on another device. Turn sync on in Settings → Sync to join again."))
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

    /// Playback stopped: publish where it stopped within seconds (watch-progress saves otherwise wait a minute, so
    /// picking up another device right away showed the old position).
    func playbackStopped() {
        guard isEnabled else { return }
        schedule(in: 3)
    }

    func syncNow() {
        guard isEnabled else { return }
        schedule(in: 0)
    }

    /// Whether the 2-minute passes run. The Mac keeps syncing in the background (cheap: small files), so a new device
    /// gets its passwords within minutes without bringing the app to the front.
    private static var appIsActive: Bool {
        #if os(macOS)
        true
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
                guard Date() >= self.quietUntil else { continue }
                // Progress saved while nothing plays (paused, closed, an episode ended): that's where it stopped, so
                // it goes out in seconds; while playing, saves come every few seconds and wait the full delay.
                let playing = self.model?.player.main.isPlaying ?? false
                self.schedule(in: tables == ["watchProgress"] && !playing ? 3 : delay)
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
        guard await ensureKey() else {
            lastError = "Waiting for this device to be unlocked to read its sync key."
            schedule(in: 30)
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
        let report = await engine.sync(folder: folder, preferences: model.prefs.cloudSyncValues(),
                                       includeSecrets: includePasswords, trustedKeys: trustedKeys,
                                       removedDevices: removedDevices)
        endAccess()
        if !report.removedDevices.isEmpty, report.removedDevices != removedDevices { removedDevices = report.removedDevices }
        if !report.trustedKeys.isEmpty, report.trustedKeys != trustedKeys { trustedKeys = report.trustedKeys }
        if report.removedThisDevice {
            await removedByAnotherDevice()
            return
        }
        // Nothing was changed; the newer pass reports.
        guard !report.cancelled else { return }
        // Applied even when a newer pass was scheduled meanwhile (that cancels this task, and the rows this pass
        // wrote trigger it): the ledger already counts these preferences as applied, so dropping them here would
        // publish the old values back on the next pass, and new playlists would never be loaded.

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
        // Another device's file is still downloading from iCloud: read it in a few seconds, not at the next
        // two-minute pass (a show watched on the Mac took minutes to reach the iPhone).
        if report.pendingDownloads > 0 { schedule(in: 8) }
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
        #if os(macOS) && !TUNER_APP_STORE
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
        guard let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            needsFolder = true
            return .failure(FolderError(message: "The sync folder can't be found any more. Choose it again."))
        }
        let accessing = url.startAccessingSecurityScopedResource()
        if stale {
            if let fresh = try? url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.folderBookmarkKey)
            } else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                needsFolder = true
                return .failure(FolderError(message: "\(Distribution.appName) lost access to the sync folder. Choose it again."))
            }
        }
        needsFolder = false
        return .success((url, { if accessing { url.stopAccessingSecurityScopedResource() } }))
        #endif
    }

    #if os(macOS) && !TUNER_APP_STORE
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
    /// A sandboxed Mac app keeps access to a picked folder across launches only through a security-scoped bookmark.
    #if os(macOS)
    private static let bookmarkCreation: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreation: URL.BookmarkCreationOptions = []
    private static let bookmarkResolution: URL.BookmarkResolutionOptions = []
    #endif

    /// A folder picked with the Files picker (the Mac App Store app: the open panel): kept as a bookmark and opened
    /// again for every pass.
    func chooseFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: Self.bookmarkCreation, includingResourceValuesForKeys: nil, relativeTo: nil)
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
        #if os(macOS) && !TUNER_APP_STORE
        folderDescription = macFolder.path
        #else
        guard let data = defaults.data(forKey: Self.folderBookmarkKey) else {
            folderDescription = nil
            needsFolder = true
            return
        }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data, options: Self.bookmarkResolution, relativeTo: nil, bookmarkDataIsStale: &stale)
        folderDescription = url?.lastPathComponent
        needsFolder = url == nil
        #endif
    }
}

#if os(iOS)
/// Sync's device id and private key in the Keychain: this device only (not in backups or iCloud Keychain), readable
/// after the first unlock so background passes work.
enum SyncKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.tuner.sync",
         kSecAttrAccount as String: account]
    }

    enum Lookup {
        case found(Data)
        case notFound
        /// The Keychain couldn't be read right now (locked since the restart, or another error): nothing is known.
        case unavailable
    }

    static func lookup(_ account: String) -> Lookup {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        switch SecItemCopyMatching(q as CFDictionary, &result) {
        case errSecSuccess: return (result as? Data).map(Lookup.found) ?? .unavailable
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }

    static func read(_ account: String) -> Data? {
        if case .found(let data) = lookup(account) { return data }
        return nil
    }

    static func write(_ account: String, _ data: Data) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
#endif
