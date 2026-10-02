import Foundation

/// File names and file-system helpers for downloads. Layout under the downloads folder (Plex/Infuse style):
///
///     Movies/<Title> (<Year>).<ext>
///     TV Shows/<Show>/Season <N>/<Show> - S01E03 - <Title>.<ext>
enum DownloadFiles {
    static let moviesFolder = "Movies"
    static let showsFolder = "TV Shows"

    /// What a download is called on disk.
    enum Naming: Sendable, Hashable {
        case movie(title: String, year: String?)
        case episode(show: String, season: Int, number: Int, title: String?)

        /// Folders under the downloads folder, and the file name without extension.
        var location: (folders: [String], name: String) {
            switch self {
            case .movie(let title, let year):
                let clean = sanitized(title)
                // Don't repeat a year the provider already put in the name.
                let name = year.map { clean.contains("(\($0))") ? clean : "\(clean) (\($0))" } ?? clean
                return ([moviesFolder], sanitized(name, maxBytes: 200))
            case .episode(let show, let season, let number, let title):
                let showName = sanitized(show)
                var name = "\(showName) - " + String(format: "S%02dE%02d", season, number)
                if let title = title.map({ sanitized($0) }), title != untitled { name += " - \(title)" }
                return ([showsFolder, showName, "Season \(season)"], sanitized(name, maxBytes: 200))
            }
        }
    }

    static let untitled = "Untitled"

    /// A safe single path component: no path separators or characters other file systems (exFAT, SMB) reject, no
    /// control characters, no leading dot (hidden) or trailing dot/space, at most `maxBytes` of UTF-8 (APFS allows
    /// 255; the rest leaves room for " (2)", the extension and ".part").
    static func sanitized(_ raw: String, maxBytes: Int = 120) -> String {
        var out = ""
        for ch in raw.replacingOccurrences(of: ": ", with: " - ") {
            switch ch {
            case "/", "\\", ":", "|": out.append("-")
            case "\"": out.append("'")
            case "*", "?", "<", ">": out.append(" ")
            default:
                out.append(ch.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : ch)
            }
        }
        var s = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let first = s.first, first == "." || first == " " { s.removeFirst() }
        if s.utf8.count > maxBytes {
            var cut = ""
            for ch in s {
                guard cut.utf8.count + String(ch).utf8.count <= maxBytes else { break }
                cut.append(ch)
            }
            s = cut
        }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        return s.isEmpty ? untitled : s
    }

    /// The episode's own title, without what providers often repeat in it ("Show - S01E03 - Title" → "Title");
    /// nil when nothing is left or it's only a placeholder ("Episode 3").
    static func episodeTitle(_ raw: String, season: Int, number: Int) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let info = TitleParser.episodeInfo(title), info.season == season, info.episode == number {
            title = info.title ?? ""
        } else if let code = title.range(of: #"^S\d{1,2}\s*E\d{1,3}[\s._\-:]*"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(code)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -_.:"))
        if title.range(of: #"^(episode|ep\.?)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return title.isEmpty ? nil : title
    }

    /// The first plausible year (1900–2099) in any of `values` ("2021", "2021-10-22").
    static func year(_ values: String?...) -> String? {
        for value in values {
            if let value, let r = value.range(of: #"(19|20)\d{2}"#, options: .regularExpression) { return String(value[r]) }
        }
        return nil
    }

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "mov", "avi", "ts", "m2ts", "mts", "webm", "mpg", "mpeg", "wmv", "flv", "3gp", "ogv", "divx", "vob",
    ]

    static let extensionsByMIME = [
        "video/mp4": "mp4", "video/x-m4v": "m4v", "video/x-matroska": "mkv", "video/matroska": "mkv", "video/quicktime": "mov",
        "video/x-msvideo": "avi", "video/avi": "avi", "video/mp2t": "ts", "video/webm": "webm", "video/mpeg": "mpg",
        "video/x-ms-wmv": "wmv", "video/x-flv": "flv",
    ]

    /// The file's extension as the server describes it: the provider's declared container (Xtream
    /// `container_extension`), then the final URL after redirects, the requested URL, the Content-Type; else mp4.
    static func fileExtension(declared: String?, response: URLResponse?, requested: URL?) -> String {
        let candidates = [declared, response?.url?.pathExtension, requested?.pathExtension]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
        if let known = candidates.first(where: videoExtensions.contains) { return known }
        if let mime = response?.mimeType?.lowercased(), let ext = extensionsByMIME[mime] { return ext }
        if let declared = candidates.first, declared.count <= 5, !declared.isEmpty,
           declared.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return declared }
        return "mp4"
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Free space for user-requested files on the volume holding `url` (macOS may purge caches to provide it).
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Renames `part` to `destination` (atomic: same folder). If something took that name meanwhile, the file gets
    /// the next free " (n)" name instead of replacing it. Returns the final URL.
    static func moveIntoPlace(_ part: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        var target = destination
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        try fm.moveItem(at: part, to: target)
        return target
    }

    /// Removes a deleted episode's "Season N" and show folders when nothing else is left in them.
    static func removeEmptyFolders(above file: URL, levels: Int) {
        let fm = FileManager.default
        var folder = file.deletingLastPathComponent()
        for _ in 0..<levels {
            guard let contents = try? fm.contentsOfDirectory(atPath: folder.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            guard (try? fm.removeItem(at: folder)) != nil else { return }
            folder = folder.deletingLastPathComponent()
        }
    }

    /// True for "the disk is full" errors from writing a file.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}
