import Foundation

public indirect enum OutValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case untrusted(String)
    case body(String)
    case array([OutValue])
    case object([String: OutValue])

    public static func date(_ date: Date) -> OutValue { .string(OutValue.iso(date)) }
    public static func optDate(_ date: Date?) -> OutValue? { date.map { .string(OutValue.iso($0)) } }

    public static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
    }

    public static func strings(_ values: [String]) -> OutValue { .array(values.map { .string($0) }) }

    public var isString: Bool {
        switch self {
        case .string, .untrusted, .body: return true
        default: return false
        }
    }

    public func mapStrings(_ transform: (OutValue) -> String) -> OutValue {
        switch self {
        case .bool, .int: return self
        case .string(let s): return .string(transform(.string(s)))
        case .untrusted(let s): return .string(transform(.untrusted(s)))
        case .body(let s): return .string(transform(.body(s)))
        case .array(let items): return .array(items.map { $0.mapStrings(transform) })
        case .object(let fields): return .object(fields.mapValues { $0.mapStrings(transform) })
        }
    }

    public var text: String {
        switch self {
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .string(let s), .untrusted(let s), .body(let s): return s
        case .array(let items): return items.map(\.text).joined(separator: ",")
        case .object: return ""
        }
    }

    public func json(pretty: Bool) -> String {
        var out = ""
        write(into: &out, pretty: pretty, depth: 0)
        return out
    }

    private static func quoted(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private func write(into out: inout String, pretty: Bool, depth: Int) {
        let pad = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: depth) : ""
        let newline = pretty ? "\n" : ""
        switch self {
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .string(let s), .untrusted(let s), .body(let s): out += Self.quoted(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, pretty: pretty, depth: depth + 1)
                out += (i < items.count - 1 ? "," : "") + newline
            }
            out += closePad + "]"
        case .object(let fields):
            if fields.isEmpty { out += "{}"; return }
            out += "{" + newline
            let keys = fields.keys.sorted()
            for (i, key) in keys.enumerated() {
                out += pad + Self.quoted(key) + (pretty ? ": " : ":")
                fields[key]!.write(into: &out, pretty: pretty, depth: depth + 1)
                out += (i < keys.count - 1 ? "," : "") + newline
            }
            out += closePad + "}"
        }
    }
}

func obj(_ pairs: KeyValuePairs<String, OutValue?>) -> OutValue {
    var fields: [String: OutValue] = [:]
    for (key, value) in pairs { if let value { fields[key] = value } }
    return .object(fields)
}

extension OutValue {
    static func optString(_ s: String?) -> OutValue? { s.map { .string($0) } }
    static func optUntrusted(_ s: String?) -> OutValue? { s.map { .untrusted($0) } }
    static func optInt(_ i: Int?) -> OutValue? { i.map { .int($0) } }
    static func optBool(_ b: Bool?) -> OutValue? { b.map { .bool($0) } }
}
