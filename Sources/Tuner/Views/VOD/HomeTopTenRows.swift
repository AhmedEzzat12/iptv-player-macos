import SwiftUI
import TunerCore

// Home's "Top 10 Movies" and "Top 10 TV Shows" (Settings › AI › Home): titles from public popularity charts
// (Netflix's weekly Top 10, else TMDB/Cinemeta) that the library has, with a big rank numeral beside each poster.
// `TopTenService` (TunerCore) fetches, caches and matches; this file only shows the result.

/// The two rows, each only when its chart matched enough of the library. Place it in Home's shelf stack.
struct HomeTopTenRows: View {
    let rows: TopTenService.Rows
    let favoriteIds: Set<String>

    var body: some View {
        if let movies = rows.movies {
            HomeTopTenShelf(title: "Top 10 Movies", subtitle: TopTenText.subtitle(movies.source),
                            items: movies.items.map(VODItem.movie), favoriteIds: favoriteIds)
        }
        if let series = rows.series {
            HomeTopTenShelf(title: "Top 10 TV Shows", subtitle: TopTenText.subtitle(series.source),
                            items: series.items.map(VODItem.series), favoriteIds: favoriteIds)
        }
    }
}

extension View {
    /// Keeps `rows` up to date while Home's Top 10 setting is on; with it off, nothing is requested and the rows
    /// stay empty. Attach to a view that's always on screen (an empty row has nothing to run a task on).
    func homeTopTenRows(_ rows: Binding<TopTenService.Rows>) -> some View {
        modifier(HomeTopTenLoader(rows: rows))
    }
}

private struct HomeTopTenLoader: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var rows: TopTenService.Rows

    private var settings: TopTenService.Settings? {
        let prefs = model.prefs
        guard prefs.homeTopTen else { return nil }
        return TopTenService.Settings(
            region: TopTenRegion(preference: prefs.homeTopTenRegion),
            deviceRegion: Locale.current.region?.identifier,
            tmdbAPIKey: prefs.tmdbAPIKey,
            language: prefs.metadataLanguage,
            hideAdultContent: prefs.hideAdultContent,
            offline: model.isOffline
        )
    }

    func body(content: Content) -> some View {
        content.task(id: HomeTopTenKey(settings: settings, library: model.libraryRevision)) {
            guard let settings else {
                if rows != TopTenService.Rows() { rows = TopTenService.Rows() }
                return
            }
            // The service only touches the network when a newer chart can exist; hourly is often enough to notice.
            while !Task.isCancelled {
                let fresh = await model.topTen.rows(settings)
                guard !Task.isCancelled else { return }
                if fresh != rows { withAnimation(.easeInOut(duration: 0.3)) { rows = fresh } }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

private struct HomeTopTenKey: Hashable {
    let settings: TopTenService.Settings?
    let library: Int
}

// MARK: - Row

private struct HomeTopTenShelf: View {
    @Environment(\.tunerCompact) private var compact
    let title: String
    let subtitle: String
    let items: [VODItem]
    let favoriteIds: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, VODMetrics.inset)
            VODShelf {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: item.route) {
                        VODRankedPosterCard(rank: index + 1, item: item, width: compact ? 116 : VODMetrics.posterWidth,
                                            isFavorite: favoriteIds.contains(item.mediaId))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        VODItemMenu(item: item, isFavorite: favoriteIds.contains(item.mediaId))
                    }
                }
            }
        }
    }
}

/// A poster with its chart position as a large numeral on its left, the poster overlapping the numeral's edge
/// (like the Top 10 rows of Netflix and the TV app).
struct VODRankedPosterCard: View {
    let rank: Int
    let item: VODItem
    var width: CGFloat = VODMetrics.posterWidth
    var isFavorite = false

    private var posterHeight: CGFloat { width * 1.5 }
    private var numeralSize: CGFloat { posterHeight * 0.66 }

    var body: some View {
        HStack(alignment: .top, spacing: -width * 0.08) {
            Text("\(rank)")
                .font(.system(size: numeralSize, weight: .heavy, design: .rounded))
                .tracking(rank >= 10 ? -numeralSize * 0.08 : 0)
                .foregroundStyle(LinearGradient(colors: [.primary.opacity(0.9), .primary.opacity(0.3)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                .lineLimit(1)
                .fixedSize()
                // Digits sit on the baseline: drop them so their foot lines up with the poster's bottom edge.
                .frame(height: posterHeight, alignment: .bottom)
                .offset(y: numeralSize * 0.1)
                .accessibilityHidden(true)
            VODPosterCard(item: item, width: width, isFavorite: isFavorite)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Number \(rank), \(item.title)")
    }
}

enum TopTenText {
    /// What the row follows: "Netflix · Egypt this week", "Popular now".
    static func subtitle(_ source: ChartSource) -> String {
        switch source {
        case .netflixCountry(let code): "Netflix · \(countryName(code)) this week"
        case .netflixGlobal: "Netflix · Worldwide this week"
        case .tmdbTrending: "Trending this week on TMDB"
        case .cinemetaPopular: "Popular now"
        }
    }

    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Countries with a Netflix Top 10, by name.
    static var countries: [(code: String, name: String)] {
        NetflixTop10.countryCodes.map { ($0, countryName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
