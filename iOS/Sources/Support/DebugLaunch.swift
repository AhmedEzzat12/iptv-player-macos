#if DEBUG
import Foundation
import TunerCore
import UIKit

/// Development hook for scripted end-to-end tests in the simulator (Debug builds only):
///   xcrun simctl launch booted <bundle id> -TunerDebugPlayMovie "Matroska Nights"
///   xcrun simctl launch booted <bundle id> -TunerDebugPlayChannel "Tuner News" [-TunerDebugEngine mpv]
/// Waits for the library, then plays the first match full screen, so each engine can be checked without tapping.
@MainActor
enum DebugLaunch {
    static func run(_ model: AppModel) async {
        let defaults = UserDefaults.standard
        // -TunerDebugAddM3U <url>: adds the playlist once (skipped when a source already has that URL).
        if let m3u = defaults.string(forKey: "TunerDebugAddM3U") {
            for _ in 0..<20 where !model.sourcesLoaded { try? await Task.sleep(for: .milliseconds(250)) }
            if !model.sources.contains(where: { $0.url == m3u }) {
                NSLog("TunerDebug: adding playlist %@", m3u)
                model.addSource(Source(name: URL(string: m3u)?.host() ?? "Debug", kind: .m3u, url: m3u))
            }
        }
        let movieName = defaults.string(forKey: "TunerDebugPlayMovie")
        let channelName = defaults.string(forKey: "TunerDebugPlayChannel")
        guard movieName != nil || channelName != nil else { return }
        // The library may still be syncing on a first launch: retry for up to 60 s.
        for _ in 0..<120 {
            if let movieName, let movie = try? await model.db.movies(search: movieName, limit: 1).first {
                NSLog("TunerDebug: playing movie %@", movie.name)
                await model.play(movie: movie, fromStart: true)
                await report(model)
                return
            }
            if let channelName, let channel = try? await model.db.channels(scope: .all, search: channelName, limit: 1).first {
                NSLog("TunerDebug: playing channel %@", channel.displayName)
                model.play(channel, fullWindow: true)
                await report(model)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        NSLog("TunerDebug: nothing matched %@", movieName ?? channelName ?? "")
    }

    /// Logs what's playing every 6 s (for `-TunerDebugReportSeconds`, default 12): engine, phase, position,
    /// picture size and codecs, plus whether the app is in the background.
    private static func report(_ model: AppModel) async {
        let seconds = max(12, UserDefaults.standard.integer(forKey: "TunerDebugReportSeconds"))
        for second in stride(from: 6, through: seconds, by: 6) {
            try? await Task.sleep(for: .seconds(6))
            let slot = model.player.main
            let s = slot.snapshot
            let state = UIApplication.shared.applicationState == .background ? "background" : "foreground"
            NSLog("TunerDebug: t+%ds [%@] engine=%@ phase=%@ position=%.1f video=%@ vcodec=%@ acodec=%@ hw=%@",
                  second, state, slot.engineName, String(describing: slot.phase), s.position ?? -1,
                  s.videoSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none",
                  s.videoCodec ?? "?", s.audioCodec ?? "?", s.hardwareDecoder ?? "?")
        }
    }
}
#endif
