#if os(macOS)
import IOKit.pwr_mgt
#else
import UIKit
#endif
import os

/// Keeps the display on while something plays. AVFoundation does this on its own, mpv doesn't, so without it the
/// iPhone dims and locks (and the Mac's display sleeps) during mpv playback. Paused, ended or failed playback lets
/// the screen sleep again.
@MainActor
enum ScreenAwake {
    private static var awakeSlots = Set<Int>()
    #if os(macOS)
    private static var assertion: IOPMAssertionID?
    #endif
    private static let log = Logger(subsystem: "app.tuner.macos", category: "ScreenAwake")

    /// Called when a player slot's phase changes.
    static func update(slot: Int, phase: PlayerSlot.Phase) {
        let wasAwake = !awakeSlots.isEmpty
        switch phase {
        case .loading, .playing, .buffering: awakeSlots.insert(slot)
        case .idle, .paused, .ended, .failed: awakeSlots.remove(slot)
        }
        let awake = !awakeSlots.isEmpty
        guard awake != wasAwake else { return }
        apply(awake)
    }

    private static func apply(_ awake: Bool) {
        log.info("Keep the screen on: \(awake, privacy: .public)")
        #if os(macOS)
        if awake, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Tuner is playing video" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id } else { log.error("Display sleep assertion failed: \(result)") }
        } else if !awake, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }
}
