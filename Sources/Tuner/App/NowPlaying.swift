import AppKit
import MediaPlayer
import TunerCore

/// Publishes the main player to macOS "Now Playing" (Control Center, lock screen, AirPods/headset controls)
/// and handles hardware media keys (play/pause, next, previous) via `MPRemoteCommandCenter`.
///
/// Mapping: live TV → next/previous = channel down/up; episodes → next = next episode;
/// movies/catchup → skip ±10 s and scrubbing.
@MainActor
final class NowPlayingController {
    private weak var model: AppModel?
    private var timer: Timer?
    private var lastSignature = ""
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        registerCommands()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Commands

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.perform { $0.player.main.setPaused(false) } ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.perform { $0.player.main.setPaused(true) } ?? .noActionableNowPlayingItem }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.perform { $0.player.main.togglePause() } ?? .noActionableNowPlayingItem }
        center.stopCommand.addTarget { [weak self] _ in self?.perform { $0.stopPlayback() } ?? .noActionableNowPlayingItem }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.perform { $0.mediaKeyNext() } ?? .noActionableNowPlayingItem }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.perform { $0.mediaKeyPrevious() } ?? .noActionableNowPlayingItem }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.perform { $0.player.main.seek(by: 10) } ?? .noActionableNowPlayingItem }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.perform { $0.player.main.seek(by: -10) } ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.perform { $0.player.main.seek(to: event.positionTime) } ?? .noActionableNowPlayingItem
        }
    }

    /// Remote commands arrive on the main thread.
    private nonisolated func perform(_ action: @escaping @MainActor (AppModel) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let model = self.model, model.player.hasMedia else { return .noActionableNowPlayingItem }
            action(model)
            self.update(force: true)
            return .success
        }
    }

    // MARK: Now Playing info

    func update(force: Bool = false) {
        guard let model else { return }
        let info = MPNowPlayingInfoCenter.default()
        let slot = model.player.main
        guard let item = slot.item else {
            if info.nowPlayingInfo != nil || force {
                info.nowPlayingInfo = nil
                info.playbackState = .stopped
                lastSignature = ""
            }
            enableCommands(for: nil)
            return
        }

        let s = slot.snapshot
        let playing = slot.phase == .playing || slot.phase == .buffering
        let program = slot.currentProgram
        // Only republish when something user-visible changed (elapsed time advances on its own via rate).
        let signature = "\(item.id)|\(playing)|\(program?.title ?? "")|\(Int((s.position ?? 0) / 15))|\(Int(s.duration ?? 0))|\(slot.rate)"
        guard force || signature != lastSignature else { return }
        lastSignature = signature

        var dict: [String: Any] = [:]
        switch item {
        case .channel(let channel):
            dict[MPMediaItemPropertyTitle] = program?.title ?? channel.displayName
            dict[MPMediaItemPropertyArtist] = channel.displayName
            if let program { dict[MPMediaItemPropertyAlbumTitle] = Fmt.timeRange(program.start, program.end) }
            dict[MPNowPlayingInfoPropertyIsLiveStream] = true
        case .catchup(let channel, let program):
            dict[MPMediaItemPropertyTitle] = program.title
            dict[MPMediaItemPropertyArtist] = channel.displayName
        case .movie(let movie):
            dict[MPMediaItemPropertyTitle] = movie.name
            if let year = movie.year { dict[MPMediaItemPropertyArtist] = year }
        case .episode(let episode, let series):
            dict[MPMediaItemPropertyTitle] = episode.title
            dict[MPMediaItemPropertyArtist] = series.name
            dict[MPMediaItemPropertyAlbumTitle] = "Season \(episode.season), Episode \(episode.number)"
        case .recording(let recording):
            dict[MPMediaItemPropertyTitle] = recording.title
            dict[MPMediaItemPropertyArtist] = recording.channelName
        }
        dict[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if !item.isLive {
            if let duration = s.duration, duration > 0 { dict[MPMediaItemPropertyPlaybackDuration] = duration }
            dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] = s.position ?? 0
        }
        dict[MPNowPlayingInfoPropertyPlaybackRate] = playing ? slot.rate : 0
        dict[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        loadArtwork(item.artworkURL)
        if let artwork { dict[MPMediaItemPropertyArtwork] = artwork }

        info.nowPlayingInfo = dict
        info.playbackState = playing ? .playing : (slot.phase == .paused ? .paused : .interrupted)
        enableCommands(for: item)
    }

    private func enableCommands(for item: PlaybackItem?) {
        let center = MPRemoteCommandCenter.shared()
        let hasItem = item != nil
        let seekable = item.map { !$0.isLive } ?? false
        center.playCommand.isEnabled = hasItem
        center.pauseCommand.isEnabled = hasItem
        center.togglePlayPauseCommand.isEnabled = hasItem
        center.stopCommand.isEnabled = hasItem
        center.nextTrackCommand.isEnabled = item.map { $0.isLive || { if case .episode = $0 { true } else { false } }($0) } ?? false
        center.previousTrackCommand.isEnabled = item?.isLive ?? false
        center.skipForwardCommand.isEnabled = seekable
        center.skipBackwardCommand.isEnabled = seekable
        center.changePlaybackPositionCommand.isEnabled = seekable
    }

    private func loadArtwork(_ url: String?) {
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        artworkTask?.cancel()
        guard let url, let parsed = URL(string: url) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: parsed), !Task.isCancelled,
                  let image = NSImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self, self.artworkURL == url else { return }
            self.artwork = art
            self.update(force: true)
        }
    }
}

extension AppModel {
    /// ⏭ media key: next channel for live TV, next episode for series.
    func mediaKeyNext() {
        switch player.main.item {
        case .channel?: channelDown()
        case .episode(let episode, let series)?: Task { await playNextEpisode(after: episode, in: series) }
        default: player.main.seek(by: 30)
        }
    }

    /// ⏮ media key: previous channel for live TV, restart for VOD.
    func mediaKeyPrevious() {
        switch player.main.item {
        case .channel?: channelUp()
        default: player.main.seek(to: 0)
        }
    }
}
