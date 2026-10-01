import Foundation

/// Accessors for the loosely-typed JSON returned by IPTV panels, where the same field can be
/// a number, a numeric string, `null`, `""` or missing depending on the server build.
public struct JSONObject: @unchecked Sendable {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]) { self.raw = raw }

    public init?(_ any: Any?) {
        guard let dict = any as? [String: Any] else { return nil }
        self.raw = dict
    }

    public subscript(key: String) -> Any? { raw[key] }

    public func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: return s.nilIfEmpty
        case let n as NSNumber:
            // Avoid "1.0" for integral values.
            if CFNumberIsFloatType(n), n.doubleValue != n.doubleValue.rounded() { return n.stringValue }
            return String(n.int64Value)
        default: return nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch raw[key] {
        case let n as NSNumber: return n.intValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            return Int(t) ?? Double(t).map { Int($0) }
        default: return nil
        }
    }

    public func double(_ key: String) -> Double? {
        switch raw[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool {
        switch raw[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }

    public func object(_ key: String) -> JSONObject? { JSONObject(raw[key]) }

    public func array(_ key: String) -> [Any] { raw[key] as? [Any] ?? [] }

    /// Unix timestamp (seconds) stored as number or string.
    public func date(_ key: String) -> Date? {
        guard let v = double(key), v > 0 else { return nil }
        return Date(timeIntervalSince1970: v)
    }
}

enum LenientJSON {
    /// Normalises list responses: `[...]` → objects; `{}` → []; a single object → [object];
    /// `{"1": {...}, "2": {...}}` keyed dictionaries → their values.
    static func objects(_ any: Any?) -> [JSONObject] {
        if let arr = any as? [Any] { return arr.compactMap { JSONObject($0) } }
        if let dict = any as? [String: Any] {
            if dict.isEmpty { return [] }
            if dict.values.allSatisfy({ $0 is [String: Any] }) && dict.keys.allSatisfy({ Int($0) != nil }) {
                return dict.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap { JSONObject($0.value) }
            }
            return [JSONObject(dict)]
        }
        return []
    }
}
