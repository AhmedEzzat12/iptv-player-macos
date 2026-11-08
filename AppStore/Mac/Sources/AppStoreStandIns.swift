import Darwin
import Foundation
import Observation
import SwiftUI

// Mac App Store build only (target TunerMac in iOS/project.yml, compiled with TUNER_APP_STORE). It stands in for
// the GitHub build's pieces the sandbox doesn't allow: Sparkle (App/Updates) and loading Homebrew's libmpv at runtime
// through the CMPV shim. Here libmpv comes from MPVKit (LGPL build), linked in.

// MARK: - CMPV stand-ins

func cmpv_is_loaded() -> Int32 { 1 }
func cmpv_load(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int32) -> Int32 { 1 }

private let openGL = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL)

/// GL entry points for libmpv's OpenGL render API (`MPVRenderer` in Player/MPVVideoLayer.swift).
func cmpv_gl_get_proc_address(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name, let openGL else { return nil }
    return dlsym(openGL, name)
}

// MARK: - Updates

/// The App Store updates the app; Settings → About and the app menu show no update controls.
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

struct UpdateCommands: Commands {
    let updater: UpdaterService

    var body: some Commands {
        EmptyCommands()
    }
}
