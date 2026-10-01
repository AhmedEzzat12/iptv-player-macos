import Foundation

/// Builds archive (catchup) URLs for M3U channels.
///
/// Supports the conventions used by Kodi's pvr.iptvsimple and ynotv:
/// - `append`: `catchup-source` appended to the live URL (default `?utc={utc}&lutc={lutc}`)
/// - `shift`: `?utc={utc}&lutc={lutc}`
/// - `flussonic`: `…/index.m3u8` → `…/index-{utc}-{duration}.m3u8`, `…/mpegts` → `…/timeshift_abs-{utc}.ts`
/// - `default`: `catchup-source` is a full URL template (falls back to `?start={utc}`)
public enum CatchupURLBuilder {
    public static func m3u(
        channelURL: String,
        type: CatchupType,
        template: String?,
        tvgId: String?,
        start: Date,
        end: Date,
        now: Date = Date()
    ) -> String {
        let vars = Variables(start: start, end: end, now: now, catchupId: tvgId)
        if let template = template?.nilIfEmpty {
            let filled = substitute(template, vars)
            if type == .append || !filled.contains("://") {
                return channelURL + filled
            }
            return filled
        }
        switch type {
        case .append, .shift:
            return appendQuery(channelURL, "utc=\(vars.startEpoch)&lutc=\(vars.nowEpoch)")
        case .flussonic:
            return flussonic(channelURL, vars)
        case .default, .xtream, .stalker:
            return appendQuery(channelURL, "utc=\(vars.startEpoch)&lutc=\(vars.nowEpoch)")
        }
    }

    struct Variables {
        let start: Date
        let end: Date
        let now: Date
        let catchupId: String?

        var startEpoch: Int { Int(start.timeIntervalSince1970) }
        var endEpoch: Int { Int(end.timeIntervalSince1970) }
        var nowEpoch: Int { Int(now.timeIntervalSince1970) }
        var durationSeconds: Int { max(0, endEpoch - startEpoch) }
        var offsetSeconds: Int { max(0, nowEpoch - startEpoch) }
    }

    static func substitute(_ template: String, _ v: Variables) -> String {
        var s = template
        let startParts = utcComponents(v.start)
        let endParts = utcComponents(v.end)

        // Parameterised forms first: {duration:60} → duration / 60, {offset:60} → offset / 60.
        s = replaceDivided(s, name: "duration", value: v.durationSeconds)
        s = replaceDivided(s, name: "offset", value: v.offsetSeconds)

        let simple: [(String, String)] = [
            ("utcend", "\(v.endEpoch)"), ("utc_end", "\(v.endEpoch)"), ("end_utc", "\(v.endEpoch)"),
            ("end-timestamp", "\(v.endEpoch)"), ("end", "\(v.endEpoch)"),
            ("lutc", "\(v.nowEpoch)"), ("now", "\(v.nowEpoch)"), ("timestamp", "\(v.nowEpoch)"),
            ("utc", "\(v.startEpoch)"), ("start-timestamp", "\(v.startEpoch)"), ("start", "\(v.startEpoch)"),
            ("duration_m", "\(v.durationSeconds / 60)"), ("duration_min", "\(v.durationSeconds / 60)"),
            ("duration", "\(v.durationSeconds)"), ("offset", "\(v.offsetSeconds)"),
            ("catchup-id", (v.catchupId ?? "").urlQueryEncoded),
            ("EY", endParts.y), ("Em", endParts.m), ("Ed", endParts.d), ("EH", endParts.h), ("EM", endParts.min), ("ES", endParts.s),
            ("Y", startParts.y), ("m", startParts.m), ("d", startParts.d), ("H", startParts.h), ("M", startParts.min), ("S", startParts.s),
        ]
        for (name, value) in simple {
            s = s.replacingOccurrences(of: "${\(name)}", with: value)
            s = s.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return s
    }

    static func replaceDivided(_ s: String, name: String, value: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\$?\\{\(name):(\\d+)\\}") else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let divR = Range(match.range(at: 1), in: result),
                  let divisor = Int(result[divR]), divisor > 0 else { continue }
            result.replaceSubrange(whole, with: "\(value / divisor)")
        }
        return result
    }

    static func flussonic(_ url: String, _ v: Variables) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        var path = comps.path
        if path.hasSuffix("/mpegts") {
            path = String(path.dropLast("mpegts".count)) + "timeshift_abs-\(v.startEpoch).ts"
        } else if let slash = path.lastIndex(of: "/"), path.hasSuffix(".m3u8") {
            let file = path[path.index(after: slash)...]
            let stem = file.dropLast(".m3u8".count)
            path = String(path[...slash]) + "\(stem)-\(v.startEpoch)-\(v.durationSeconds).m3u8"
        } else {
            return appendQuery(url, "timeshift=\(v.startEpoch)")
        }
        comps.path = path
        return comps.string ?? url
    }

    static func appendQuery(_ url: String, _ query: String) -> String {
        url + (url.contains("?") ? "&" : "?") + query
    }

    static func utcComponents(_ date: Date) -> (y: String, m: String, d: String, h: String, min: String, s: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return (String(c.year ?? 1970), two(c.month), two(c.day), two(c.hour), two(c.minute), two(c.second))
    }
}
