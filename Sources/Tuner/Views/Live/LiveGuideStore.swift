import SwiftUI
import TunerCore

/// Asks the guide grid to scroll a channel row into view (`token` makes repeated requests distinct).
struct LiveGuideScrollRequest: Equatable {
    var channelId: String
    var anchor: UnitPoint?
    var token: Int
}

/// What the channel list was loaded for. A change (new category, search, sort) scrolls the guide to the top.
struct LiveGuideListSignature: Hashable {
    var scope: ChannelScope
    var search: String
    var sort: ChannelSort
    var hideAdult: Bool
}

/// State shared by the Live TV header, filter bar and guide grid: the channel list, selection,
/// the clock and time window, and programmes loaded lazily for the rows on screen.
@MainActor
@Observable
final class LiveGuideStore {
    static let fetchPadding: TimeInterval = 3600
    /// Programme lists kept for at most this many EPG keys; beyond it, off-screen keys are dropped.
    static let maxCachedKeys = 2500

    // MARK: Clock & time window

    /// Refreshed every 30 s: now line, progress fills, past/current styling.
    var now = Date() { didSet { ensureProgramRange() } }
    /// Hours the window is shifted from "now" with ‹ / ›.
    var hourOffset = 0 { didSet { if hourOffset != oldValue { ensureProgramRange() } } }
    /// Hours visible in the grid (derived from its width by the grid).
    var visibleHours: Double = 3 { didSet { if visibleHours != oldValue { ensureProgramRange() } } }

    /// Now floored to the half hour, minus 30 minutes, plus the user's shift.
    var windowStart: Date { Self.baseStart(for: now).addingTimeInterval(Double(hourOffset) * 3600) }
    var windowEnd: Date { windowStart.addingTimeInterval(visibleHours * 3600) }

    // MARK: Channels & categories

    private(set) var channels: [Channel] = []
    /// False until the first channel list arrives (avoids flashing empty states).
    private(set) var hasLoaded = false
    private(set) var categories: [ChannelCategory] = []
    /// Source whose categories the filter bar shows (nil = all sources).
    var sourceFilter: String?

    // MARK: Selection

    /// Channel shown in the header: the last one clicked, else the playing one.
    var selectedChannel: Channel?
    /// Row highlighted for ↑/↓ navigation.
    var keyboardChannelId: String?
    /// The highlight ring shows only while navigating with the keyboard (not after mouse clicks).
    private(set) var isKeyboardNavigating = false
    private(set) var scrollRequest: LiveGuideScrollRequest?

    // MARK: Dialogs (presented by LiveTVView so they survive rows scrolling away)

    var renameTarget: Channel?
    var renameText = ""
    var newGroupTarget: Channel?
    var newGroupName = ""

    // MARK: Programmes

    /// Programmes by EPG key (may be from a previous window until refreshed).
    private(set) var programs: [String: [Program]] = [:]
    /// Keys fetched for the current window and guide revision.
    private(set) var loadedKeys: Set<String> = []
    /// Optimistic favourite state until the database round-trip reloads the list.
    private(set) var favoriteOverrides: [String: Bool] = [:]

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var indexById: [String: Int] = [:]
    @ObservationIgnored private var signature: LiveGuideListSignature?
    @ObservationIgnored private var scrollToken = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var visibleCounts: [String: Int] = [:]
    @ObservationIgnored private var pendingKeys: Set<String> = []
    @ObservationIgnored private var fetchDebounce: Task<Void, Never>?
    @ObservationIgnored private var fetchRange: (from: Date, to: Date)?
    @ObservationIgnored private var generation = 0

    func attach(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        if selectedChannel == nil { selectedChannel = model.player.main.item?.channel }
        ensureProgramRange()
        scheduleFetch()
    }

    // MARK: - Clock

    /// Ticks `now` on 30-second boundaries until cancelled.
    func runClock() async {
        while !Task.isCancelled {
            now = Date()
            let delay = 30 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
            try? await Task.sleep(for: .seconds(max(1, delay)))
        }
    }

    static func baseStart(for date: Date) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.minute = (c.minute ?? 0) < 30 ? 0 : 30
        let floored = cal.date(from: c) ?? date
        return floored.addingTimeInterval(-1800)
    }

    /// ≈300 pt per hour, 1.5–4 hours.
    static func visibleHours(forWidth width: CGFloat) -> Double {
        min(4, max(1.5, Double(width) / 300))
    }

    func shiftWindow(by hours: Int) {
        hourOffset = min(24 * 7, max(-48, hourOffset + hours))
    }

    // MARK: - Channels

    func setChannels(_ list: [Channel], signature newSignature: LiveGuideListSignature) {
        let firstLoad = !hasLoaded
        let listChanged = signature != newSignature
        signature = newSignature
        if list != channels {
            channels = list
            var index: [String: Int] = [:]
            index.reserveCapacity(list.count)
            for (i, c) in list.enumerated() where index[c.id] == nil { index[c.id] = i }
            indexById = index
        }
        hasLoaded = true

        if !favoriteOverrides.isEmpty {
            favoriteOverrides = favoriteOverrides.filter { id, value in
                guard let i = indexById[id] else { return selectedChannel?.id == id }
                return channels[i].isFavorite != value
            }
        }
        if let selected = selectedChannel, let fresh = channel(id: selected.id), fresh != selected {
            selectedChannel = fresh
        }
        let playing = model?.player.main.item?.channel
        if selectedChannel == nil, let playing {
            selectedChannel = channel(id: playing.id) ?? playing
        }
        if firstLoad {
            if let id = playing?.id, indexById[id] != nil { requestScroll(to: id, anchor: .center) }
        } else if listChanged, let first = channels.first {
            keyboardChannelId = nil
            requestScroll(to: first.id, anchor: .top)
        }
    }

    func setCategories(_ list: [ChannelCategory]) {
        if list != categories { categories = list }
    }

    func channel(id: String) -> Channel? {
        indexById[id].map { channels[$0] }
    }

    func contains(_ channelId: String) -> Bool { indexById[channelId] != nil }

    /// Replaces the header channel with a freshly loaded copy (when it isn't in the current list).
    func refreshSelected(_ fresh: Channel) {
        guard selectedChannel?.id == fresh.id else { return }
        if selectedChannel != fresh { selectedChannel = fresh }
        if let value = favoriteOverrides[fresh.id], value == fresh.isFavorite {
            favoriteOverrides[fresh.id] = nil
        }
    }

    // MARK: - Selection & playback

    func select(_ channel: Channel) {
        selectedChannel = channel
        keyboardChannelId = channel.id
        if isKeyboardNavigating { isKeyboardNavigating = false }
    }

    /// Click behaviour: preview the channel; if it's already the one playing, open the full-window player.
    func activate(_ channel: Channel) {
        guard let model else { return }
        previewTask?.cancel()
        select(channel)
        let main = model.player.main
        if main.item?.isLive == true, main.item?.channel?.id == channel.id, main.phase.isActive {
            model.enterFullWindow()
        } else {
            model.play(channel)
        }
    }

    /// Main-player channel changed (click, zapping in full screen, reminders): follow it.
    func followPlaying(_ channel: Channel?) {
        guard let channel else { return }
        selectedChannel = self.channel(id: channel.id) ?? channel
        keyboardChannelId = channel.id
        if indexById[channel.id] != nil { requestScroll(to: channel.id, anchor: nil) }
    }

    /// ↑/↓ navigation: moves the highlight immediately and previews after a short pause.
    func moveSelection(by delta: Int) {
        guard !channels.isEmpty else { return }
        let currentId = keyboardChannelId ?? selectedChannel?.id ?? model?.player.main.item?.channel?.id
        let next: Int
        if let currentId, let i = indexById[currentId] {
            next = min(channels.count - 1, max(0, i + delta))
        } else {
            next = delta >= 0 ? 0 : channels.count - 1
        }
        let channel = channels[next]
        select(channel)
        isKeyboardNavigating = true
        requestScroll(to: channel.id, anchor: nil)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.model?.play(channel)
        }
    }

    func moveToEdge(top: Bool) {
        moveSelection(by: top ? -channels.count : channels.count)
    }

    /// Return in the grid: watch the highlighted channel full window.
    func openSelection() {
        previewTask?.cancel()
        guard let channel = keyboardChannelId.flatMap({ self.channel(id: $0) }) ?? selectedChannel else { return }
        model?.play(channel, fullWindow: true)
    }

    func requestScroll(to channelId: String, anchor: UnitPoint?) {
        scrollToken += 1
        scrollRequest = LiveGuideScrollRequest(channelId: channelId, anchor: anchor, token: scrollToken)
    }

    func cancelPendingPreview() {
        previewTask?.cancel()
    }

    // MARK: - Favourites

    func isFavorite(_ channel: Channel) -> Bool {
        favoriteOverrides[channel.id] ?? channel.isFavorite
    }

    func toggleFavorite(_ channel: Channel) {
        var current = channel
        current.isFavorite = isFavorite(channel)
        favoriteOverrides[channel.id] = !current.isFavorite
        model?.toggleFavorite(current)
    }

    // MARK: - Dialogs

    func beginRename(_ channel: Channel) {
        renameText = channel.displayName
        renameTarget = channel
    }

    func beginNewGroup(_ channel: Channel) {
        newGroupName = ""
        newGroupTarget = channel
    }

    // MARK: - Programmes (lazy, per visible row)

    func programs(for channel: Channel) -> [Program]? {
        channel.epgKey.flatMap { programs[$0] }
    }

    /// True when the channel's guide data for the current window has been fetched (or it has none to fetch).
    func isLoaded(_ channel: Channel) -> Bool {
        guard let key = channel.epgKey else { return true }
        return loadedKeys.contains(key)
    }

    func rowAppeared(_ key: String?) {
        guard let key else { return }
        visibleCounts[key, default: 0] += 1
        if !loadedKeys.contains(key) {
            pendingKeys.insert(key)
            scheduleFetch()
        }
    }

    func rowDisappeared(_ key: String?) {
        guard let key, let n = visibleCounts[key] else { return }
        visibleCounts[key] = n > 1 ? n - 1 : nil
    }

    /// Guide data changed: refetch what's on screen (stale programmes stay visible meanwhile).
    func invalidatePrograms() {
        generation += 1
        if !loadedKeys.isEmpty { loadedKeys = [] }
        pendingKeys.formUnion(visibleCounts.keys)
        scheduleFetch()
    }

    private func ensureProgramRange() {
        let start = windowStart
        let end = windowEnd
        if let range = fetchRange, range.from <= start, range.to >= end { return }
        fetchRange = (start.addingTimeInterval(-Self.fetchPadding), end.addingTimeInterval(Self.fetchPadding))
        invalidatePrograms()
    }

    private func scheduleFetch() {
        guard !pendingKeys.isEmpty else { return }
        fetchDebounce?.cancel()
        fetchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.startFetch()
        }
    }

    private func startFetch() {
        guard let db = model?.db else { return } // attach() reschedules
        if fetchRange == nil { ensureProgramRange() }
        guard let range = fetchRange else { return }
        let keys = pendingKeys.filter { visibleCounts[$0] != nil && !loadedKeys.contains($0) }
        pendingKeys.removeAll()
        guard !keys.isEmpty else { return }
        let gen = generation
        // Not tied to the debounce task, so a later debounce can't cancel an in-flight read.
        Task { [weak self] in
            let result = (try? await db.programs(epgKeys: Array(keys), from: range.from, to: range.to)) ?? [:]
            guard let self, gen == self.generation else { return }
            var map = self.programs
            for key in keys { map[key] = result[key] ?? [] }
            var loaded = self.loadedKeys.union(keys)
            if map.count > Self.maxCachedKeys {
                map = map.filter { self.visibleCounts[$0.key] != nil }
                loaded = loaded.filter { map[$0] != nil }
            }
            self.programs = map
            self.loadedKeys = loaded
        }
    }

    // MARK: - Helpers

    /// Past (or current) programme the provider's archive still holds.
    static func catchupAvailable(_ channel: Channel, _ program: Program, now: Date) -> Bool {
        guard channel.hasCatchup, program.start < now else { return false }
        if let days = channel.catchupDays, days > 0 {
            return program.start >= now.addingTimeInterval(-Double(days) * 86400)
        }
        return true
    }

    func title(for scope: ChannelScope, model: AppModel) -> String {
        switch scope {
        case .all: return "Live TV"
        case .favorites: return "Favorites"
        case .recent: return "Recently Watched"
        case .group(let id): return model.customGroups.first { $0.id == id }?.name ?? "Group"
        case .category(let id): return categories.first { $0.id == id }?.displayName ?? "Live TV"
        case .source(let id): return model.sources.first { $0.id == id }?.name ?? "Live TV"
        }
    }
}
