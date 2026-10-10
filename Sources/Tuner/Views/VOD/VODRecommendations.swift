import SwiftUI
import TunerCore

// Settings › AI › Recommendations: "More Like This" on movie and show pages and "Because You Watched" rows on Home.
// The work happens in `Recommender` (TunerCore, off the main actor); these views only ask and show. With the
// preference off they're never created (detail pages) or load nothing (Home), so pages look exactly as without them.

/// "More Like This" poster shelf for a movie or show page. The page adds it only when `items` isn't empty (an empty
/// shelf in the page's stack would still take its spacing); `vodMoreLikeThis` fills `items`.
struct VODMoreLikeThisShelf: View {
    @Environment(AppModel.self) private var model
    let items: [VODItem]

    @ViewState private var favoriteIds: Set<String> = []

    var body: some View {
        VODShelf("More Like This") {
            ForEach(items) { item in
                NavigationLink(value: item.route) {
                    VODPosterCard(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    VODItemMenu(item: item, isFavorite: favoriteIds.contains(item.mediaId))
                }
            }
        }
        .task(id: model.userRevision) {
            favoriteIds = (try? await model.db.vodFavoriteIds()) ?? []
        }
    }
}

extension View {
    /// Fills `items` with titles like `item` while Settings › AI › Recommendations is on (empties it when off). The
    /// page's own details and online metadata make the query, so the list sharpens when they arrive.
    func vodMoreLikeThis(_ item: VODItem, metadata: MediaMetadata?, items: Binding<[VODItem]>) -> some View {
        modifier(VODMoreLikeThisLoader(item: item, metadata: metadata, items: items))
    }
}

private struct VODMoreLikeThisLoader: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: VODItem
    let metadata: MediaMetadata?
    @Binding var items: [VODItem]

    func body(content: Content) -> some View {
        content.task(id: VODMoreLikeThisKey(item: item, metadata: metadata?.fetchedAt, library: model.libraryRevision,
                                            hideAdult: model.prefs.hideAdultContent,
                                            enabled: model.prefs.aiRecommendations)) {
            await load()
        }
    }

    private func load() async {
        guard model.prefs.aiRecommendations else {
            if !items.isEmpty { items = [] }
            return
        }
        let recommender = model.recommender
        let revision = model.libraryRevision
        let hideAdult = model.prefs.hideAdultContent
        let result: [VODItem]
        switch item {
        case .movie(let movie):
            result = await recommender.moreLike(movie: movie, metadata: metadata, libraryRevision: revision, hideAdult: hideAdult)
                .map(VODItem.movie)
        case .series(let series):
            result = await recommender.moreLike(series: series, metadata: metadata, libraryRevision: revision, hideAdult: hideAdult)
                .map(VODItem.series)
        }
        guard !Task.isCancelled, result != items else { return }
        withAnimation(.easeInOut(duration: 0.3)) { items = result }
    }
}

/// Reloads when the title (or its details), its metadata, the library or the adult filter change.
private struct VODMoreLikeThisKey: Hashable {
    let item: VODItem
    /// When the online metadata was fetched (cheaper to compare than the whole record).
    let metadata: Date?
    let library: Int
    let hideAdult: Bool
    let enabled: Bool
}

/// A "Because You Watched …" row for Home.
struct VODRecommendationRow: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [VODItem]
}

extension View {
    /// Fills `rows` with up to two "Because You Watched" rows while Settings › AI › Recommendations is on (and empties
    /// them when it's off). Reloads when the library, the user's history/favourites or the adult filter change.
    func vodRecommendationRows(_ rows: Binding<[VODRecommendationRow]>) -> some View {
        modifier(VODRecommendationRowsLoader(rows: rows))
    }
}

private struct VODRecommendationRowsLoader: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var rows: [VODRecommendationRow]

    func body(content: Content) -> some View {
        content.task(id: Key(enabled: model.prefs.aiRecommendations, library: model.libraryRevision, user: model.userRevision,
                             hideAdult: model.prefs.hideAdultContent)) {
            await load()
        }
    }

    private struct Key: Hashable {
        let enabled: Bool
        let library: Int
        let user: Int
        let hideAdult: Bool
    }

    private func load() async {
        guard model.prefs.aiRecommendations else {
            if !rows.isEmpty { rows = [] }
            return
        }
        // Progress is saved every few seconds while something plays: coalesce bursts of user-state changes.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let found = await model.recommender.becauseYouWatched(libraryRevision: model.libraryRevision,
                                                              hideAdult: model.prefs.hideAdultContent)
        guard !Task.isCancelled else { return }
        let result = found.map { row in
            let name = TitleMatcher.cleanTitle(row.seed.name, kind: Self.kind(row.seed))
            return VODRecommendationRow(
                id: row.id,
                title: row.reason == .watched ? "Because You Watched \(name)" : "Because You Liked \(name)",
                items: row.titles.map(Self.item)
            )
        }
        if result != rows { rows = result }
    }

    private static func kind(_ title: Recommender.Title) -> MediaMetadata.Kind {
        if case .series = title { return .series }
        return .movie
    }

    private static func item(_ title: Recommender.Title) -> VODItem {
        switch title {
        case .movie(let m): .movie(m)
        case .series(let s): .series(s)
        }
    }
}
