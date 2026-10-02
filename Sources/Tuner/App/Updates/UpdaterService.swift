import AppKit
import Observation
import Sparkle
import SwiftUI

/// Sparkle auto-updates from the appcast attached to each GitHub release (the same setup as Soonbar).
/// Only builds that carry an update-signing public key (`scripts/release.sh` adds it) turn it on: a build without
/// one couldn't verify an update, so it never checks. Scratch runs (TUNER_DATA_DIR) stay off too unless
/// TUNER_UPDATE_FEED points them at a test feed.
@MainActor
@Observable
final class UpdaterService: NSObject, SPUUpdaterDelegate {
    static let shared = UpdaterService()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let scratchRun = TunerApp.dataDirectoryOverride != nil && Self.feedOverride == nil
        if !publicKey.isEmpty && !scratchRun {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
        // On unless the user turned it off (SUEnableAutomaticChecks in Info.plist sets the default).
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        canCheck = controller?.updater.canCheckForUpdates ?? false
        canCheckObservation = controller?.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            Task { @MainActor in self?.canCheck = self?.controller?.updater.canCheckForUpdates ?? false }
        }
    }

    var isEnabled: Bool { controller != nil }

    /// False while a check or an update is already under way.
    private(set) var canCheck = false

    /// Stored so Settings observes it; Sparkle keeps the user's choice in its own defaults.
    var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Test runs serve their own appcast (see docs/testing.md).
    private static let feedOverride = ProcessInfo.processInfo.environment["TUNER_UPDATE_FEED"]

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["TUNER_UPDATE_FEED"]
    }
}

/// "Check for Updates…" in the app menu, right after About Tuner (release builds only).
struct UpdateCommands: Commands {
    let updater: UpdaterService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
    }
}
