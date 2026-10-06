import Foundation
import Observation

/// iOS stand-in for the macOS Sparkle updater (Sources/Tuner/App/Updates/UpdaterService.swift). The iPhone/iPad
/// build is installed from Xcode, so it never self-updates; Settings › About shows updates as off.
@MainActor
@Observable
final class UpdaterService {
    static let shared = UpdaterService()

    private init() {}

    var isEnabled: Bool { false }
    private(set) var canCheck = false
    var automaticallyChecks = false
    var lastCheck: Date? { nil }

    func checkForUpdates() {}
}
