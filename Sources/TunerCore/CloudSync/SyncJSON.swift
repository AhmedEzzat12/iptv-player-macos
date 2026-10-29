import CryptoKit
import Foundation

/// A JSON value: the payload of a synced record and of a synced preference. Numbers are always `Double` so a value
/// read back from another device's file hashes the same as the one built locally.
public enum SyncJSON: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SyncJSON])
    case object([String: SyncJSON])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([SyncJSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: SyncJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Building

    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: Int64) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ values: [String]) { self = .array(values.map { .string($0) }) }

    // MARK: Reading

    public subscript(key: String) -> SyncJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Whole numbers only (a fractional or out-of-range number reads as nil).
    public var int: Int? {
        guard case .number(let n) = self, n.rounded() == n, abs(n) < 9.0e15 else { return nil }
        return Int(n)
    }

    public var int64: Int64? { int.map(Int64.init) }

    public var array: [SyncJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// An array of strings (nil when it isn't one).
    public var strings: [String]? {
        guard let array else { return nil }
        let list = array.compactMap(\.string)
        return list.count == array.count ? list : nil
    }

    public var isNull: Bool { self == .null }

    // MARK: Hashing

    /// Short content hash over canonical JSON (sorted keys), used to notice changed values.
    public var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
