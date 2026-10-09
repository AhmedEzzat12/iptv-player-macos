import Foundation
import GRDB

/// Natural-language search: understood filters applied to movies and series (see `QueryUnderstanding`).
extension AppDatabase {
    /// Parses a search and keeps it plain when the whole query names a title in the library ("Family Guy",
    /// "That '90s Show", "Top Gun"): an exact title beats any reading of its words as filters.
    public func understandSearch(_ query: String, currentYear: Int = QueryUnderstanding.currentYear) async -> ParsedSearch {
        let parsed = QueryUnderstanding.parse(query, currentYear: currentYear)
        guard parsed.hasFilters else { return parsed }
        if (try? await isLibraryTitle(parsed.query)) == true { return .plain(parsed.query) }
        return parsed
    }

    /// Whether a movie or series in the library is called `query` (see `QueryUnderstanding.title(_:matches:)`).
    public func isLibraryTitle(_ query: String) async throws -> Bool {
        let words = QueryUnderstanding.titleKey(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        return try await writer.read { db in
            for table in ["movie", "series"] {
                var sql = "SELECT name FROM \(table) WHERE 1"
                var args: [any DatabaseValueConvertible] = []
                for word in words {
                    let patterns = QueryUnderstanding.spellings(word)
                    sql += " AND (" + patterns.map { _ in "name LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
                    args += patterns.map { "%\(Self.escapeLike($0))%" }
                }
                sql += " LIMIT 500"
                let names = try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                if names.contains(where: { QueryUnderstanding.title($0, matches: query) }) { return true }
            }
            return false
        }
    }

    /// Movies matching an understood search (empty when it asks for series only).
    public func movies(understood search: ParsedSearch, limit: Int = 200) async throws -> [Movie] {
        guard search.kind != .series else { return [] }
        return try await writer.read { db in
            let (sql, args) = try Self.understoodSQL(db, table: "movie", categoryKind: .movie, search: search, limit: limit)
            return try Movie.fetchAll(db, sql: sql, arguments: args)
        }
    }

    /// Series matching an understood search (empty when it asks for movies only).
    public func series(understood search: ParsedSearch, limit: Int = 200) async throws -> [Series] {
        guard search.kind != .movie else { return [] }
        return try await writer.read { db in
            let (sql, args) = try Self.understoodSQL(db, table: "series", categoryKind: .series, search: search, limit: limit)
            return try Series.fetchAll(db, sql: sql, arguments: args)
        }
    }

    /// Year: the provider's year, else the release date's ("2015", "2015-05-01"); unknown years never match.
    /// Genres: all of them, each from the title's genre text or its category name. Languages: any of them, from the
    /// category name or the title. 4K: category or title. Top rated: rating ≥ `ParsedSearch.topRatedMinimum`.
    static func understoodSQL(_ db: Database, table: String, categoryKind: CategoryKind, search: ParsedSearch, limit: Int) throws -> (String, StatementArguments) {
        let categories = try Row.fetchAll(db, sql: """
            SELECT cat.id, cat.name, cp.alias FROM category cat
            LEFT JOIN categoryPref cp ON cp.categoryId = cat.id
            WHERE cat.kind = ?
            """, arguments: [categoryKind]).map { row -> (id: String, text: String, group: CategoryGroup) in
            let name: String = row["name"]
            let alias: String? = row["alias"]
            let text = " " + CategoryClassifier.normalized(name + " " + (alias ?? "")) + " "
            return (row["id"], text, CategoryClassifier.facet(for: name).group)
        }
        func categoryIds(_ stems: [String], group: CategoryGroup? = nil) -> [String] {
            categories.filter { cat in
                (group != nil && cat.group == group) || stems.contains { Self.wordStart($0, in: cat.text) }
            }.map(\.id)
        }

        var sql = """
            SELECT m.* FROM \(table) m
            JOIN source s ON s.id = m.sourceId AND s.enabled = 1 AND s.includeVOD = 1
            LEFT JOIN categoryPref cp ON cp.categoryId = m.categoryId
            WHERE COALESCE(cp.isHidden, 0) = 0
            """
        var args: [any DatabaseValueConvertible] = []

        /// "(m.categoryId IN (…) OR <column> LIKE … OR …)"; "0" when nothing can match.
        func anyOf(categories ids: [String], likes: [(column: String, pattern: String)]) -> String {
            var parts: [String] = []
            if !ids.isEmpty {
                parts.append("m.categoryId IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")")
                args += ids
            }
            for like in likes {
                parts.append("\(like.column) LIKE ? ESCAPE '\\'")
                args.append(like.pattern)
            }
            return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
        }

        for word in searchWords(search.text) {
            sql += " AND m.name LIKE ? ESCAPE '\\'"
            args.append("%\(escapeLike(word))%")
        }

        if let years = search.years {
            let year = "CAST(substr(COALESCE(NULLIF(trim(m.year), ''), m.releaseDate), 1, 4) AS INTEGER)"
            if let from = years.from { sql += " AND \(year) >= ?"; args.append(from) }
            if let to = years.to { sql += " AND \(year) BETWEEN 1 AND ?"; args.append(to) }
        }

        for genre in search.genres {
            let likes = genre.stems.flatMap { stem in
                QueryUnderstanding.spellings(stem.trimmingCharacters(in: .whitespaces)).map { ("m.genre", "%\(escapeLike($0))%") }
            }
            sql += " AND " + anyOf(categories: categoryIds(genre.stems, group: genre == .kids ? .kids : nil), likes: likes)
        }

        if !search.languages.isEmpty {
            var ids: [String] = []
            var likes: [(column: String, pattern: String)] = []
            for language in search.languages {
                ids += categoryIds(language.stems)
                for word in language.titleWords {
                    likes += QueryUnderstanding.spellings(word).map { ("m.name", "%\(escapeLike($0))%") }
                }
                if let tag = language.tag {
                    likes += ["\(tag) - %", "\(tag): %", "\(tag):%", "\(tag) | %", "\(tag)|%", "[\(tag)]%", "|\(tag)|%", "(\(tag))%"]
                        .map { ("m.name", $0) }
                }
            }
            sql += " AND " + anyOf(categories: Array(Set(ids)), likes: likes)
        }

        if search.wants4K {
            let ids = categoryIds(["4k", "uhd", "2160", "فائقه الجوده"])
            sql += " AND " + anyOf(categories: ids, likes: ["%4k%", "%uhd%", "%2160p%"].map { ("m.name", $0) })
        }

        if search.topRated {
            sql += " AND m.rating >= ?"
            args.append(ParsedSearch.topRatedMinimum)
        }

        if search.text.isEmpty || search.topRated {
            sql += " ORDER BY m.rating IS NULL, m.rating DESC, m.addedAt IS NULL, m.addedAt DESC, m.providerOrder"
        } else {
            sql += " ORDER BY " + vodOrder(.name, alias: "m")
        }
        sql += " LIMIT \(limit)"
        return (sql, StatementArguments(args))
    }

    /// Whether `stem` starts a word of `text` (normalized, padded with spaces), also after an Arabic article or
    /// conjunction ("الرعب", "والكوميديا"). A stem ending in a space must be a whole word.
    static func wordStart(_ stem: String, in text: String) -> Bool {
        for prefix in ["", "ال", "وال", "بال", "و"] where text.contains(" " + prefix + stem) {
            return true
        }
        return false
    }
}
