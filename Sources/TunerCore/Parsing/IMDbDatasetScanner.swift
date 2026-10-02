import Foundation
import zlib

enum IMDbDatasetError: LocalizedError, Sendable {
    case unreadable
    case notGzip
    case corrupt

    var errorDescription: String? {
        switch self {
        case .unreadable: "Could not open the IMDb dataset"
        case .notGzip: "The IMDb dataset is not a gzip file"
        case .corrupt: "The IMDb dataset is damaged or truncated"
        }
    }
}

/// Byte-level scans of IMDb's non-commercial TSV datasets (gzip, header row, `\N` = unknown):
///
/// - `title.episode.tsv.gz`: `tconst  parentTconst  seasonNumber  episodeNumber` (~10M rows, 260 MB inflated)
/// - `title.ratings.tsv.gz`: `tconst  averageRating  numVotes` (~1.7M rows)
///
/// Files are inflated as a stream (system zlib, 1 MB of whole lines at a time), never as a whole and never as
/// per-line Strings; an episode row is only parsed past its parent id when that's one being looked for. Title ids
/// are compared by their numeric part ("tt0903747" → 903747). About 0.5 s for the episode file in a release build
/// on Apple silicon (`memmem` for the parent was measured slower than this per-line check once optimised).
enum IMDbDatasetScanner {
    /// Where an episode belongs.
    struct EpisodeRef: Sendable, Hashable {
        var series: Int
        var season: Int
        var episode: Int
    }

    /// A dataset file that couldn't be read (so it can be downloaded again).
    struct FileError: LocalizedError, Sendable {
        var file: URL
        var reason: IMDbDatasetError

        var errorDescription: String? { "\(file.lastPathComponent): \(reason.localizedDescription)" }
    }

    /// Ratings for each requested series id (every valid requested id is present; [] when nothing is rated),
    /// sorted by season and episode. Invalid ids are ignored.
    static func scan(episodesFile: URL, ratingsFile: URL, seriesIds: Set<String>,
                     bufferSize: Int = defaultBufferSize) throws -> [String: [EpisodeRating]] {
        var requested: [Int: [String]] = [:]
        for id in seriesIds {
            if let number = titleNumber(id) { requested[number, default: []].append(id) }
        }
        var result: [String: [EpisodeRating]] = [:]
        for ids in requested.values { for id in ids { result[id] = [] } }
        guard !requested.isEmpty else { return result }

        let episodes = try reading(episodesFile) {
            try self.episodes(inGzipFile: episodesFile, seriesNumbers: Set(requested.keys), bufferSize: bufferSize)
        }
        guard !episodes.isEmpty else { return result }
        let rated = try reading(ratingsFile) { try ratings(inGzipFile: ratingsFile, for: episodes, bufferSize: bufferSize) }
        for (series, ratings) in rated {
            for id in requested[series] ?? [] { result[id] = ratings }
        }
        return result
    }

    private static func reading<T>(_ file: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let reason as IMDbDatasetError {
            throw FileError(file: file, reason: reason)
        }
    }

    /// Episodes (by title number) of the given series. Rows with an unknown season or episode are skipped.
    static func episodes(inGzipFile url: URL, seriesNumbers: Set<Int>,
                         bufferSize: Int = defaultBufferSize) throws -> [Int: EpisodeRef] {
        var out: [Int: EpisodeRef] = [:]
        guard !seriesNumbers.isEmpty else { return out }
        // A few parents (the usual case) are compared directly, which beats hashing ~10M parent ids.
        let few = seriesNumbers.count <= 8 ? Array(seriesNumbers) : nil
        try GzipLines.forEachChunk(inFile: url, bufferSize: bufferSize) { chunk in
            GzipLines.forEachLine(in: chunk) { line in
                // tconst \t parentTconst \t season \t episode — the parent is checked before anything else is parsed.
                let n = line.count
                var i = 0
                while i < n && line[i] != tab { i += 1 }
                guard let (parent, afterParent) = parseTitle(line, from: i + 1), afterParent < n, line[afterParent] == tab,
                      few?.contains(parent) ?? seriesNumbers.contains(parent),
                      let (episodeId, afterId) = parseTitle(line, from: 0), afterId == i,
                      let (season, afterSeason) = parseInt(line, from: afterParent + 1), afterSeason < n,
                      line[afterSeason] == tab,
                      let (number, _) = parseInt(line, from: afterSeason + 1)
                else { return }
                out[episodeId] = EpisodeRef(series: parent, season: season, episode: number)
            }
        }
        return out
    }

    /// Ratings of the given episodes, grouped by series. When a season/episode appears twice (IMDb duplicates),
    /// the entry with more votes wins.
    static func ratings(inGzipFile url: URL, for episodes: [Int: EpisodeRef],
                        bufferSize: Int = defaultBufferSize) throws -> [Int: [EpisodeRating]] {
        var best: [EpisodeRef: EpisodeRating] = [:]
        try GzipLines.forEachChunk(inFile: url, bufferSize: bufferSize) { chunk in
            GzipLines.forEachLine(in: chunk) { line in
                guard let (id, afterId) = parseTitle(line, from: 0), afterId < line.count, line[afterId] == tab,
                      let ref = episodes[id],
                      let (rating, afterRating) = parseDecimal(line, from: afterId + 1), afterRating < line.count,
                      line[afterRating] == tab,
                      let (votes, _) = parseInt(line, from: afterRating + 1),
                      rating <= 10
                else { return }
                if let existing = best[ref], existing.votes >= votes { return }
                best[ref] = EpisodeRating(season: ref.season, episode: ref.episode, rating: rating, votes: votes)
            }
        }
        var out: [Int: [EpisodeRating]] = [:]
        for (ref, rating) in best { out[ref.series, default: []].append(rating) }
        for key in out.keys {
            out[key]?.sort { ($0.season, $0.episode) < ($1.season, $1.episode) }
        }
        return out
    }

    // MARK: - Fields

    static let defaultBufferSize = 1 << 20
    private static let tab = UInt8(ascii: "\t")
    private static let zero = UInt8(ascii: "0")
    private static let maxDigits = 12

    /// "tt0903747" → 903747; nil for anything else.
    static func titleNumber(_ id: String) -> Int? {
        Array(id.utf8).withUnsafeBufferPointer { buffer -> Int? in
            guard let (number, end) = parseTitle(buffer, from: 0), end == buffer.count else { return nil }
            return number
        }
    }

    /// `tt` + 1–12 digits at `i`; returns the number and the index after it.
    @inline(__always)
    private static func parseTitle(_ line: UnsafeBufferPointer<UInt8>, from i: Int) -> (Int, Int)? {
        guard i + 2 < line.count, line[i] == UInt8(ascii: "t"), line[i + 1] == UInt8(ascii: "t") else { return nil }
        return parseInt(line, from: i + 2)
    }

    /// 1–12 ASCII digits at `i` (`\N` and empty fields are nil); returns the value and the index after it.
    @inline(__always)
    private static func parseInt(_ line: UnsafeBufferPointer<UInt8>, from i: Int) -> (Int, Int)? {
        var j = i
        var value = 0
        while j < line.count {
            let d = line[j] &- zero
            guard d < 10 else { break }
            value = value &* 10 &+ Int(d)
            j += 1
        }
        guard j > i, j - i <= maxDigits else { return nil }
        return (value, j)
    }

    /// "8.6" / "10" / "7.25" → Double; returns the value and the index after it.
    @inline(__always)
    private static func parseDecimal(_ line: UnsafeBufferPointer<UInt8>, from i: Int) -> (Double, Int)? {
        guard let (whole, afterWhole) = parseInt(line, from: i) else { return nil }
        guard afterWhole < line.count, line[afterWhole] == UInt8(ascii: ".") else { return (Double(whole), afterWhole) }
        guard let (fraction, end) = parseInt(line, from: afterWhole + 1) else { return nil }
        var scale = 1.0
        for _ in 0..<(end - afterWhole - 1) { scale *= 10 }
        // An exact integer over a power of ten is correctly rounded: 86 / 10 == 8.6.
        return ((Double(whole) * scale + Double(fraction)) / scale, end)
    }
}

/// Streams a gzip file (multi-member aware, via zlib's `gzread`) without holding the inflated file.
enum GzipLines {
    /// Calls `body` with consecutive chunks of whole lines (each ends with `\n`, except a final line without one).
    /// A chunk is only valid during the call. Throws for files that can't be opened, aren't gzip, or are
    /// damaged or truncated.
    static func forEachChunk(inFile url: URL, bufferSize: Int = 1 << 20,
                             _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        guard let file = gzopen(url.path, "rb") else { throw IMDbDatasetError.unreadable }
        defer { gzclose(file) }
        gzbuffer(file, 1 << 18)
        // gzread passes plain files through unchanged; an HTML error page must not look like an empty dataset.
        guard gzdirect(file) == 0 else { throw IMDbDatasetError.notGzip }

        var capacity = max(bufferSize, 16)
        var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var filled = 0
        while true {
            if filled == capacity {
                // A line longer than the buffer: grow it.
                let bigger = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * 2)
                bigger.update(from: buffer, count: filled)
                buffer.deallocate()
                buffer = bigger
                capacity *= 2
            }
            let read = gzread(file, buffer + filled, UInt32(min(capacity - filled, Int(Int32.max))))
            if read < 0 { throw IMDbDatasetError.corrupt }
            if read == 0 { break }
            let scanFrom = filled
            filled += Int(read)
            // Hand over everything up to the last newline; keep the partial line for the next read.
            var lineEnd = filled
            while lineEnd > scanFrom && buffer[lineEnd - 1] != UInt8(ascii: "\n") { lineEnd -= 1 }
            guard lineEnd > scanFrom else { continue } // (the carried partial line has no newline)
            try body(UnsafeBufferPointer(start: buffer, count: lineEnd))
            filled -= lineEnd
            if filled > 0 { memmove(buffer, buffer + lineEnd, filled) }
        }
        // gzread reports a truncated stream as a plain end of file; gzerror tells them apart.
        var status = Z_OK
        _ = gzerror(file, &status)
        guard status == Z_OK || status == Z_STREAM_END else { throw IMDbDatasetError.corrupt }
        if filled > 0 { try body(UnsafeBufferPointer(start: buffer, count: filled)) }
    }

    /// Calls `body` with each line of a chunk, without its `\n`.
    @inline(__always)
    static func forEachLine(in chunk: UnsafeBufferPointer<UInt8>, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        guard let base = chunk.baseAddress else { return }
        var start = 0
        while start < chunk.count {
            let end = memchr(base + start, 0x0A, chunk.count - start)
                .map { UnsafeRawPointer(base).distance(to: UnsafeRawPointer($0)) } ?? chunk.count
            body(UnsafeBufferPointer(start: base + start, count: end - start))
            start = end + 1
        }
    }

    /// Every line of a gzip file, without its `\n` (tests and diagnostics).
    static func forEach(inFile url: URL, bufferSize: Int = 1 << 20,
                        _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        try forEachChunk(inFile: url, bufferSize: bufferSize) { chunk in
            var failure: Error?
            forEachLine(in: chunk) { line in
                guard failure == nil else { return }
                do { try body(line) } catch { failure = error }
            }
            if let failure { throw failure }
        }
    }
}
