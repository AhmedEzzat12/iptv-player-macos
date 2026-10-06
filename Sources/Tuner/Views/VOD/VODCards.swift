#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import TunerCore

// Shared building blocks for Home, Movies, TV Shows and Search: the movie/show item wrapper,
// navigation routes, cards (poster, landscape, live "On Now"), horizontal shelves and small helpers.

// MARK: - Metrics & theme

enum VODMetrics {
    /// Leading/trailing inset of shelves and page content.
    #if os(macOS)
    static let inset: CGFloat = 32
    #else
    static let inset: CGFloat = 20
    #endif
    static let shelfSpacing: CGFloat = 18
    static let posterWidth: CGFloat = 150
    static let landscapeWidth: CGFloat = 300
    static let posterCorner: CGFloat = 10
    static let landscapeCorner: CGFloat = 12

    /// Detail page hero height for a given page height (~64 %, clamped).
    static func detailHeroHeight(for viewHeight: CGFloat) -> CGFloat {
        min(max(viewHeight * 0.64, 400), 620)
    }

    /// Home hero height for a given page height (~62 %, clamped).
    static func homeHeroHeight(for viewHeight: CGFloat) -> CGFloat {
        min(max(viewHeight * 0.62, 380), 560)
    }
}

enum VODTheme {
    /// Page background; heroes fade into it. Near-black in dark mode like the TV app, the standard
    /// window background in light mode.
    static let background = Color(nsColor: NSColor(name: "TunerVODBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.06, green: 0.06, blue: 0.065, alpha: 1)
            : .windowBackgroundColor
    })

    /// Soft fade from a hero into the page background (applied outside the hero's forced dark scheme).
    static var heroBottomFade: some View {
        LinearGradient(colors: [.clear, background], startPoint: .top, endPoint: .bottom)
            .frame(height: 28)
            .allowsHitTesting(false)
    }
}

// MARK: - Item & routes

/// A movie or a show, so cards, shelves and the hero can treat both alike.
enum VODItem: Hashable, Identifiable {
    case movie(Movie)
    case series(Series)

    var id: String {
        switch self {
        case .movie(let m): "m:\(m.id)"
        case .series(let s): "s:\(s.id)"
        }
    }

    /// Database id (favourites, progress).
    var mediaId: String {
        switch self {
        case .movie(let m): m.id
        case .series(let s): s.id
        }
    }

    var title: String {
        switch self {
        case .movie(let m): m.name
        case .series(let s): s.name
        }
    }

    var year: String? {
        switch self {
        case .movie(let m): VODFormat.year(m.year, releaseDate: m.releaseDate)
        case .series(let s): VODFormat.year(s.year, releaseDate: s.releaseDate)
        }
    }

    var posterURL: String? {
        switch self {
        case .movie(let m): m.posterURL?.nilIfEmpty
        case .series(let s): s.coverURL?.nilIfEmpty
        }
    }

    var backdropURL: String? {
        switch self {
        case .movie(let m): m.backdropURL?.nilIfEmpty
        case .series(let s): s.backdropURL?.nilIfEmpty
        }
    }

    /// Provider rating; zero means "unknown" for most panels.
    var rating: Double? {
        let r: Double?
        switch self {
        case .movie(let m): r = m.rating
        case .series(let s): r = s.rating
        }
        guard let r, r > 0 else { return nil }
        return r
    }

    var plot: String? {
        switch self {
        case .movie(let m): m.plot?.nilIfEmpty
        case .series(let s): s.plot?.nilIfEmpty
        }
    }

    var genre: String? {
        switch self {
        case .movie(let m): m.genre?.nilIfEmpty
        case .series(let s): s.genre?.nilIfEmpty
        }
    }

    var isMovie: Bool {
        if case .movie = self { return true }
        return false
    }

    var kindLabel: String { isMovie ? "Movie" : "TV Show" }
    var placeholderSymbol: String { isMovie ? "film" : "tv" }

    /// `MediaKind` has no series case; series favourites are stored with `.episode` (the favourite
    /// queries join on the media id, so the kind is informational only).
    var favoriteKind: MediaKind { isMovie ? .movie : .episode }

    var route: VODRoute {
        switch self {
        case .movie(let m): .movie(m)
        case .series(let s): .series(s)
        }
    }

    /// "2019 · Drama · ★ 7.4"
    var metadataLine: String {
        var parts: [String] = []
        if let year { parts.append(year) }
        if let g = VODFormat.genres(genre, max: 2) { parts.append(g) }
        if let rating { parts.append("★ \(VODFormat.rating(rating))") }
        return parts.joined(separator: " · ")
    }
}

/// Drill-down destinations pushed on a section's `NavigationStack`.
enum VODRoute: Hashable {
    case movie(Movie)
    case series(Series)
}

extension View {
    /// Registers the movie/show detail pages for `VODRoute` values.
    func vodDestinations() -> some View {
        navigationDestination(for: VODRoute.self) { route in
            switch route {
            case .movie(let m): MovieDetailView(movie: m)
            case .series(let s): SeriesDetailView(series: s)
            }
        }
    }

    /// Mirrors artwork under the floating sidebar/toolbar on macOS 26 (no-op before).
    @ViewBuilder
    func vodBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }
}

// MARK: - Actions

@MainActor
enum VODActions {
    /// Plays a movie (resuming) or the next-up episode of a show.
    static func play(_ item: VODItem, model: AppModel) {
        switch item {
        case .movie(let m):
            Task { await model.play(movie: m) }
        case .series(let s):
            Task { await playNextUp(s, model: model) }
        }
    }

    /// Plays the episode to watch next (resume, or the one after the last finished), loading episodes if needed.
    static func playNextUp(_ series: Series, model: AppModel) async {
        var episodes = (try? await model.db.episodes(seriesId: series.id)) ?? []
        if episodes.isEmpty { episodes = (try? await model.sync.episodes(for: series)) ?? [] }
        let progress = (try? await model.db.progress(seriesId: series.id)) ?? [:]
        guard let next = VODUpNext.find(episodes: episodes, progress: progress) else {
            model.notify(Banner(symbol: "tv", title: "No episodes available", message: series.name, isError: true))
            return
        }
        await model.play(episode: next.episode, in: series)
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Copies a movie's resolved stream URL.
    static func copyStreamURL(_ movie: Movie, model: AppModel) {
        Task {
            do {
                let stream = try await model.resolver.movie(movie)
                copyToPasteboard(stream.url.absoluteString)
                model.notify(Banner(symbol: "doc.on.doc", title: "Stream URL copied", message: movie.name))
            } catch {
                model.notify(Banner(symbol: "exclamationmark.triangle.fill", title: "Couldn't resolve stream", message: error.localizedDescription, isError: true))
            }
        }
    }
}

/// The episode a "Play" button on a show should start.
struct VODUpNext {
    let episode: Episode
    /// True when the episode has a resume point.
    let resume: Bool

    var label: String {
        "\(resume ? "Resume" : "Play") \(VODFormat.episodeCode(episode))"
    }

    /// Resumes the most recently watched unfinished episode, otherwise continues after the most recently
    /// finished one; falls back to the first episode.
    static func find(episodes: [Episode], progress: [String: WatchProgress]) -> VODUpNext? {
        let sorted = episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        guard let first = sorted.first else { return nil }
        func isResumable(_ e: Episode) -> Bool {
            guard let p = progress[e.id] else { return false }
            return !p.completed && p.position > 10
        }
        let ids = Set(sorted.map(\.id))
        guard let latest = progress.values.filter({ ids.contains($0.mediaId) }).max(by: { $0.updatedAt < $1.updatedAt }),
              let index = sorted.firstIndex(where: { $0.id == latest.mediaId })
        else { return VODUpNext(episode: first, resume: false) }

        let current = sorted[index]
        if !latest.completed { return VODUpNext(episode: current, resume: isResumable(current)) }
        if let next = sorted[(index + 1)...].first(where: { progress[$0.id]?.completed != true }) {
            return VODUpNext(episode: next, resume: isResumable(next))
        }
        return VODUpNext(episode: first, resume: false)
    }
}

// MARK: - Formatting

enum VODFormat {
    static func year(_ year: String?, releaseDate: String?) -> String? {
        if let y = year?.nilIfEmpty, y != "0" { return String(y.prefix(4)) }
        if let d = releaseDate?.nilIfEmpty, d.count >= 4 {
            let y = String(d.prefix(4))
            if Int(y) != nil { return y }
        }
        return nil
    }

    static func rating(_ value: Double) -> String { String(format: "%.1f", value) }

    /// First `max` genres of a comma/slash separated list.
    static func genres(_ value: String?, max: Int) -> String? {
        guard let value = value?.nilIfEmpty else { return nil }
        let parts = value.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(max).joined(separator: ", ")
    }

    /// "12 min left", "1 hr 5 min left"
    static func timeLeft(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) hr left" : "\(h) hr \(m) min left"
    }

    static func timeLeft(_ progress: WatchProgress) -> String {
        timeLeft(max(0, progress.duration - progress.position))
    }

    /// "S1, E3" (season 0 → "Special 3")
    static func episodeCode(_ e: Episode) -> String {
        e.season == 0 ? "Special \(e.number)" : "S\(e.season), E\(e.number)"
    }

    static func seasonTitle(_ season: Int) -> String { season == 0 ? "Specials" : "Season \(season)" }

    /// A YouTube watch URL for an id or any http(s) URL given by the provider.
    static func trailerURL(_ value: String?) -> URL? {
        guard let raw = value?.nilIfEmpty else { return nil }
        if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard raw.count >= 8, raw.count <= 20, raw.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(raw)")
    }
}

/// Deterministic colours and initials for artwork placeholders.
enum VODPalette {
    static func hue(_ string: String) -> Double {
        var h: UInt64 = 5381
        for b in string.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }

    static func initials(_ string: String) -> String {
        let words = string.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0) } }
        return letters.joined().uppercased()
    }

    static func gradient(for string: String, brightness: Double = 0.42) -> LinearGradient {
        let hue = hue(string)
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.42, brightness: brightness),
                Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: brightness * 0.42),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Artwork

/// Gradient tile with a symbol and initials, shown while artwork loads or when there is none.
struct VODArtworkPlaceholder: View {
    let title: String
    var symbol: String = "film"

    var body: some View {
        VODPalette.gradient(for: title)
            .overlay {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    VStack(spacing: side * 0.06) {
                        Image(systemName: symbol)
                            .font(.system(size: side * 0.14, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                        let initials = VODPalette.initials(title)
                        if !initials.isEmpty {
                            Text(initials)
                                .font(.system(size: side * 0.26, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
    }
}

/// Fills its frame with artwork: the backdrops in order of preference, else a blurred enlarged fallback
/// (the poster), else a placeholder.
///
/// Each backdrop is its own layer that stays transparent until its image loads, with the preferred one on
/// top. So a broken provider URL falls through to the online one, and a backdrop that arrives later (online
/// metadata) fades in over what's showing instead of flashing the placeholder.
struct VODBackdropArtwork: View {
    let title: String
    let backdropURLs: [String]
    let fallbackURL: String?
    var symbol: String = "film"

    /// Backdrops that have loaded; once one has, the blurred fallback underneath is dropped (it's hidden,
    /// and a large blur is costly to composite while the page scrolls).
    @ViewState private var loaded: Set<String> = []

    init(title: String, backdropURLs: [String?], fallbackURL: String?, symbol: String = "film") {
        self.title = title
        var seen = Set<String>()
        self.backdropURLs = backdropURLs.compactMap { $0?.nilIfEmpty }.filter { seen.insert($0).inserted }
        self.fallbackURL = fallbackURL
        self.symbol = symbol
    }

    var body: some View {
        Color.clear
            .overlay {
                if loaded.isDisjoint(with: backdropURLs) {
                    blurredFallback
                }
            }
            .overlay {
                ZStack {
                    // Least preferred first, so the preferred backdrop draws on top.
                    ForEach(backdropURLs.reversed(), id: \.self) { url in
                        layer(url)
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layer(_ url: String) -> some View {
        if let parsed = URL(string: url), parsed.scheme != nil {
            Color.clear.overlay {
                AsyncImage(url: parsed, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                    if case .success(let image) = phase {
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .task {
                                // Let the fade-in finish before removing what's underneath.
                                try? await Task.sleep(for: .milliseconds(500))
                                loaded.insert(url)
                            }
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var blurredFallback: some View {
        if let fallbackURL {
            RemoteImage(url: fallbackURL) { VODArtworkPlaceholder(title: title, symbol: symbol) }
                .scaleEffect(1.35)
                .blur(radius: 36, opaque: true)
                .overlay(Color.black.opacity(0.15))
        } else {
            VODArtworkPlaceholder(title: title, symbol: symbol)
        }
    }
}

/// The title as artwork: the transparent title logo from online metadata when there is one (like the TV
/// app), else bold text. The text shows until the logo has loaded and stays if it can't be loaded.
struct VODTitleArtwork: View {
    let title: String
    let logoURL: String?
    var fontSize: CGFloat = 38
    var maxLogoWidth: CGFloat = 420
    var maxLogoHeight: CGFloat = 110
    /// Also show `title` as text under the logo, so the playlist's own name stays visible (detail pages).
    var showsTitleUnderLogo = false

    @ViewState private var logo: NSImage?

    var body: some View {
        Group {
            if let logo, logo.size.width > 0, logo.size.height > 0 {
                let size = fittedSize(logo.size)
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .shadow(color: .black.opacity(0.45), radius: 12)
                        .accessibilityRemoveTraits(.isImage)
                        .accessibilityLabel(title)
                    if showsTitleUnderLogo {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .shadow(color: .black.opacity(0.35), radius: 6)
                            .accessibilityHidden(true)
                    }
                }
                .transition(.opacity)
            } else {
                Text(title)
                    .font(.system(size: fontSize, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 8)
                    .transition(.opacity)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .task(id: logoURL) { await load() }
    }

    /// Aspect-fit inside the maximum box, so wide and tall logos both get their natural shape.
    private func fittedSize(_ natural: CGSize) -> CGSize {
        let aspect = natural.width / natural.height
        let width = min(maxLogoWidth, maxLogoHeight * aspect)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    private func load() async {
        guard let raw = logoURL?.nilIfEmpty, let url = URL(string: raw), url.scheme != nil else {
            logo = nil
            return
        }
        // URLSession.shared uses the app's enlarged URLCache, like AsyncImage.
        guard let (data, response) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = NSImage(data: data), Self.isLegibleOnDark(image)
        else { return }
        withAnimation(.easeInOut(duration: 0.35)) { logo = image }
    }

    /// Heroes are dark, so a black or very dark logo would disappear; such logos fall back to the text title.
    /// Averages the luminance of the logo's visible pixels on a tiny copy.
    static func isLegibleOnDark(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        var luminance = 0.0
        var coverage = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.1 else { continue }
            // Premultiplied: the colour channels already carry the alpha weighting.
            luminance += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
            coverage += alpha
        }
        guard coverage > 0 else { return false }
        return luminance / coverage > 0.15
    }
}

// MARK: - Online metadata

/// How online metadata (Cinemeta, or TMDB with a key) is merged with what the provider sent.
///
/// The provider's values win where it has them — its plot may be in the user's language and its duration
/// is the actual file's — and metadata fills the gaps. Metadata wins only where providers are weak: ratings
/// with a named source, cast with photos, and the title logo. Backdrops are layered (see `VODBackdropArtwork`).
enum VODEnrichment {
    /// Label for the metadata's rating ("IMDb" for Cinemeta, whose ratings are IMDb's).
    static func ratingSource(_ metadata: MediaMetadata) -> String {
        switch metadata.source.lowercased() {
        case "cinemeta", "imdb": "IMDb"
        case "tmdb", "themoviedb": "TMDB"
        default: metadata.source
        }
    }

    /// The metadata's rating with its source, else the provider's (unlabelled) rating.
    static func rating(provider: Double?, metadata: MediaMetadata?) -> VODRating? {
        if let metadata, let r = metadata.rating, r > 0 { return VODRating(source: ratingSource(metadata), value: r) }
        if let r = provider, r > 0 { return VODRating(source: nil, value: r) }
        return nil
    }

    /// The provider's genres ("Action, Drama", "Action / Drama"), else the metadata's.
    static func genres(provider: String?, metadata: MediaMetadata?) -> [String] {
        let own = split(provider, on: ",/|")
        return own.isEmpty ? unique(metadata?.genres ?? []) : own
    }

    /// The metadata's cast (photos, characters), else the provider's comma-separated names.
    static func cast(provider: String?, metadata: MediaMetadata?) -> [CastMember] {
        if let cast = metadata?.cast.filter({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }), !cast.isEmpty {
            return cast
        }
        return split(provider, on: ",|;").map { CastMember(name: $0) }
    }

    /// The provider's text (e.g. its director), else the metadata's list joined.
    static func people(provider: String?, metadata: [String]?) -> String? {
        if let own = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return own }
        let list = unique(metadata ?? [])
        return list.isEmpty ? nil : list.joined(separator: ", ")
    }

    /// The provider's trailer, else the metadata's YouTube trailer.
    static func trailerURL(provider: String?, metadata: MediaMetadata?) -> URL? {
        VODFormat.trailerURL(provider) ?? VODFormat.trailerURL(metadata?.trailerYouTubeId)
    }

    /// The provider's duration (the actual file), else the catalogue runtime.
    static func runtimeSeconds(provider: Int?, metadata: MediaMetadata?) -> Int? {
        if let s = provider, s > 0 { return s }
        if let m = metadata?.runtimeMinutes, m > 0 { return m * 60 }
        return nil
    }

    static func year(_ year: String?, releaseDate: String?, metadata: MediaMetadata?) -> String? {
        VODFormat.year(year, releaseDate: releaseDate) ?? VODFormat.year(metadata?.year, releaseDate: metadata?.releaseDate)
    }

    /// The original-language title when it differs from the names already shown.
    static func originalTitle(_ metadata: MediaMetadata?, shown names: [String]) -> String? {
        guard let original = metadata?.originalTitle?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        let folded = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let same = names.contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(folded) }
        return same ? nil : original
    }

    /// "22 October 2021" for "2021-10-22" or an ISO timestamp (read in UTC so the day doesn't shift);
    /// anything else is returned as is.
    static func date(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return nil }
        let day = String(raw.prefix(10))
        guard day.count == 10, let date = dayParser.date(from: day) else { return raw }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .gmt
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Metadata from Cinemeta", plus TVmaze when its episode pictures are used (its data licence requires credit).
    static func credit(_ metadata: MediaMetadata) -> String {
        let usesTVmaze = metadata.episodes.contains { [$0.stillURL, $0.fallbackStillURL].contains { $0?.contains("tvmaze.com") == true } }
        return usesTVmaze ? "Metadata from \(metadata.source) · Episode pictures from TVmaze" : "Metadata from \(metadata.source)"
    }

    /// The title's IMDb page, when the metadata has a valid IMDb id ("tt1160419").
    static func imdbURL(_ metadata: MediaMetadata?) -> URL? {
        guard let id = imdbId(metadata) else { return nil }
        return URL(string: "https://www.imdb.com/title/\(id)/")
    }

    /// A show's episode list for one season on IMDb (per-episode IMDb ids aren't in the metadata).
    static func imdbEpisodesURL(_ metadata: MediaMetadata?, season: Int) -> URL? {
        guard season > 0, let id = imdbId(metadata) else { return nil }
        return URL(string: "https://www.imdb.com/title/\(id)/episodes/?season=\(season)")
    }

    private static func imdbId(_ metadata: MediaMetadata?) -> String? {
        guard let id = metadata?.imdbId?.trimmingCharacters(in: .whitespaces).lowercased(), id.hasPrefix("tt"),
              id.count > 2, id.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return id
    }

    private static func split(_ value: String?, on separators: String) -> [String] {
        guard let value = value?.nilIfEmpty else { return [] }
        let set = Set(separators)
        return unique(value.split(whereSeparator: { set.contains($0) }).map(String.init))
    }

    /// Trimmed, non-empty, first occurrence only.
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// Re-runs a page's metadata lookup when the item or the metadata settings change.
struct VODMetadataTaskKey: Hashable {
    let id: String
    let settings: MetadataSettings
}

/// A rating and where it comes from.
struct VODRating: Equatable {
    /// "IMDb", "TMDB"; nil for the provider's own unlabelled rating.
    var source: String?
    var value: Double
}

/// "[IMDb] 8.0" with a small outlined source tag, or "★ 7.4" for an unlabelled rating.
struct VODRatingBadge: View {
    let rating: VODRating

    var body: some View {
        Group {
            if let source = rating.source {
                HStack(spacing: 5) {
                    Text(source)
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.foreground.opacity(0.75), lineWidth: 1))
                    Text(VODFormat.rating(rating.value))
                }
            } else {
                Text("★ \(VODFormat.rating(rating.value))")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rating.source.map { "\($0) rating \(VODFormat.rating(rating.value))" } ?? "Rating \(VODFormat.rating(rating.value))")
    }
}

/// Small capsules for genres (as many as fit, up to four).
struct VODGenreChips: View {
    let genres: [String]

    var body: some View {
        if !genres.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(4)
                chips(3)
                chips(2)
                chips(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Genres: " + genres.prefix(4).joined(separator: ", "))
        }
    }

    private func chips(_ count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(genres.prefix(count)), id: \.self) { genre in
                Text(genre)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.foreground.opacity(0.14)))
            }
        }
    }
}

/// "Cast" shelf: round photos (initials when there's none), name and character.
struct VODCastShelf: View {
    let cast: [CastMember]

    var body: some View {
        VODShelf("Cast") {
            ForEach(Array(cast.prefix(30).enumerated()), id: \.offset) { _, member in
                VODCastCard(member: member)
            }
        }
    }
}

struct VODCastCard: View {
    let member: CastMember
    private let side: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(VODPalette.gradient(for: member.name, brightness: 0.5))
                .frame(width: side, height: side)
                .overlay {
                    let initials = VODPalette.initials(member.name)
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.system(size: side * 0.36))
                            .foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text(initials)
                            .font(.system(size: side * 0.32, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .overlay {
                    if let photo = member.photoURL?.nilIfEmpty {
                        RemoteImage(url: photo) { Color.clear }
                    }
                }
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
            VStack(spacing: 2) {
                Text(member.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let character = member.character?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
                    Text(character)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 116, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// Hero action that opens the title on IMDb: a glass capsule with an outlined "IMDb" tag.
struct VODIMDbButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text("IMDb")
                .font(.system(size: 12, weight: .heavy))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 1.2))
                .padding(.vertical, 1)
        }
        .buttonStyle(GlassButtonStyle())
        .help("View on IMDb")
        .accessibilityLabel("View on IMDb")
    }
}

/// Subtle "Metadata from Cinemeta" line at the bottom of detail pages.
struct VODMetadataCredit: View {
    let metadata: MediaMetadata

    var body: some View {
        Label(VODEnrichment.credit(metadata), systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help("Ratings, cast, title artwork and details your provider doesn't supply come from \(metadata.source). You can change this in Settings → Metadata.")
    }
}

// MARK: - Cards

/// 2:3 poster with title and year underneath; optional watch progress.
struct VODPosterCard: View {
    let item: VODItem
    /// Fixed width for shelves; `nil` fills the grid column.
    var width: CGFloat? = VODMetrics.posterWidth
    var progress: Double?
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork.hoverLift(scale: 1.05)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let year = item.year { Text(year) }
                    if let rating = item.rating {
                        Label(VODFormat.rating(rating), systemImage: "star.fill")
                            .labelStyle(VODCompactLabelStyle())
                    }
                    if isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(.pink.opacity(0.85))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                RemoteImage(url: item.posterURL) {
                    VODArtworkPlaceholder(title: item.title, symbol: item.placeholderSymbol)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    ProgressCapsule(fraction: progress, height: 4, tint: .white)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: VODMetrics.posterCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VODMetrics.posterCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

/// 16:9 card with the title over a gradient (Continue Watching, episodes elsewhere).
struct VODLandscapeCard: View {
    let title: String
    var subtitle: String?
    var caption: String?
    var imageURL: String?
    var symbol: String = "play.rectangle"
    var progress: Double?
    var width: CGFloat = VODMetrics.landscapeWidth

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RemoteImage(url: imageURL) { VODArtworkPlaceholder(title: title, symbol: symbol) }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                    if progress != nil || caption != nil {
                        HStack(spacing: 8) {
                            if let progress {
                                ProgressCapsule(fraction: progress, height: 4, tint: .white)
                                    .frame(maxWidth: 120)
                            }
                            if let caption {
                                Text(caption)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 3)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
            .frame(width: width)
            .hoverLift()
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Live channel card: programme artwork (or a tinted gradient) with the channel logo, current programme
/// title, time left, a programme progress capsule and a LIVE pill.
struct VODOnNowCard: View {
    let channel: Channel
    let program: Program?
    var width: CGFloat = VODMetrics.landscapeWidth

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        .frame(width: width)
        .hoverLift()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func card(now: Date) -> some View {
        let current = program.flatMap { $0.end > now ? $0 : nil }
        let icon = current?.iconURL?.nilIfEmpty
        return Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(VODPalette.gradient(for: channel.displayName, brightness: 0.34))
            .overlay {
                if let icon {
                    RemoteImage(url: icon) { Color.clear }
                }
            }
            .overlay {
                LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: icon == nil ? .center : .topLeading) {
                ChannelLogo(url: channel.logoURL, name: channel.displayName, size: icon == nil ? 46 : 30)
                    .padding(icon == nil ? 0 : 10)
                    .offset(y: icon == nil ? -16 : 0)
                    .shadow(color: .black.opacity(0.3), radius: 6)
            }
            .overlay(alignment: .topTrailing) {
                VODLivePill().padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(current?.title ?? channel.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(detailLine(current, now: now))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    if let current {
                        ProgressCapsule(fraction: current.progress(at: now), height: 3, tint: .white)
                            .padding(.top, 2)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VODMetrics.landscapeCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
    }

    private func detailLine(_ program: Program?, now: Date) -> String {
        guard let program else { return "No guide information" }
        return "\(channel.displayName) · \(Fmt.remaining(until: program.end, now: now))"
    }
}

/// Red "LIVE" capsule.
struct VODLivePill: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.red))
            .accessibilityLabel("Live")
    }
}

/// Icon + text with tight spacing (ratings).
struct VODCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Context menu

/// Play / favourite / copy actions for a movie or show card.
struct VODItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: VODItem
    let isFavorite: Bool

    var body: some View {
        Button {
            VODActions.play(item, model: model)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            let item = item
            Task { await model.toggleVODFavorite(mediaId: item.mediaId, kind: item.favoriteKind) }
        } label: {
            Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "heart.slash" : "heart")
        }
        Divider()
        Button {
            VODActions.copyToPasteboard(item.title)
        } label: {
            Label("Copy Title", systemImage: "doc.on.doc")
        }
        if case .movie(let movie) = item {
            Button {
                VODActions.copyStreamURL(movie, model: model)
            } label: {
                Label("Copy Stream URL", systemImage: "link")
            }
        }
    }
}

// MARK: - Shelf

/// A titled horizontal row of cards with view-aligned scrolling and prev/next chevrons on hover.
struct VODShelf<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    @ViewState private var position = ScrollPosition(edge: .leading)
    /// Latest scroll geometry, kept out of observation so scrolling doesn't re-render the shelf.
    @ViewState private var geometry = VODShelfGeometryBox()
    @ViewState private var edges = VODShelfEdges()
    @ViewState private var hovering = false

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                ShelfHeader(title: title, subtitle: subtitle)
                    .padding(.horizontal, VODMetrics.inset)
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: VODMetrics.shelfSpacing) {
                    content()
                }
                .scrollTargetLayout()
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, VODMetrics.inset, for: .scrollContent)
            .scrollPosition($position)
            .onScrollGeometryChange(for: VODShelfMetrics.self) { geo in
                let minX = -geo.contentInsets.leading
                let maxX = max(minX, geo.contentSize.width + geo.contentInsets.trailing - geo.containerSize.width)
                return VODShelfMetrics(offset: geo.contentOffset.x, minOffset: minX, maxOffset: maxX, page: geo.containerSize.width)
            } action: { _, new in
                geometry.metrics = new
                let e = VODShelfEdges(canGoBack: new.offset > new.minOffset + 2, canGoForward: new.offset < new.maxOffset - 2)
                if e != edges { edges = e }
            }
            .overlay(alignment: .leading) {
                if hovering, edges.canGoBack {
                    chevron("chevron.left", help: "Previous") { page(by: -1) }
                        .padding(.leading, 8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if hovering, edges.canGoForward {
                    chevron("chevron.right", help: "Next") { page(by: 1) }
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
        }
    }

    private func chevron(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(0.35)))
                .tunerGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .zIndex(2)
    }

    private func page(by direction: CGFloat) {
        let metrics = geometry.metrics
        let target = metrics.offset + direction * max(200, metrics.page - VODMetrics.inset * 2)
        withAnimation(.smooth(duration: 0.45)) {
            if target <= metrics.minOffset + 1 {
                position.scrollTo(edge: .leading)
            } else if target >= metrics.maxOffset - 1 {
                position.scrollTo(edge: .trailing)
            } else {
                position.scrollTo(x: target)
            }
        }
    }
}

private struct VODShelfMetrics: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var page: CGFloat = 0
}

private struct VODShelfEdges: Equatable {
    var canGoBack = false
    var canGoForward = false
}

/// Plain (non-observable) holder for the shelf's scroll geometry.
private final class VODShelfGeometryBox {
    var metrics = VODShelfMetrics()
}

// MARK: - Shared page pieces

/// Large page title used by browse and search pages.
struct VODPageTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Capsule filter chip (category rows).
struct VODChip: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                if let count {
                    Text(count.formatted())
                        .foregroundStyle(isSelected ? AnyShapeStyle(.background.opacity(0.65)) : AnyShapeStyle(.tertiary))
                }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.08)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}
