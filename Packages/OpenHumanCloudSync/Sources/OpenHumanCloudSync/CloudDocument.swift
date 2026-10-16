import Crypto
import Foundation

public enum CloudValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case array([CloudValue])
    case object([String: CloudValue])
}

// Why: tagged so an integer never comes back as a double, which would change digests and cause false conflicts
extension CloudValue: Codable {
    private enum Tag: String, CodingKey { case b, i, d, s, x, a, o }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        let keys = container.allKeys
        guard let tag = keys.first else { self = .null; return }
        guard keys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "ambiguous value"))
        }
        switch tag {
        case .b: self = .bool(try container.decode(Bool.self, forKey: .b))
        case .i: self = .int(try container.decode(Int64.self, forKey: .i))
        case .d: self = .double(try container.decode(Double.self, forKey: .d))
        case .s: self = .string(try container.decode(String.self, forKey: .s))
        case .x: self = .data(try container.decode(Data.self, forKey: .x))
        case .a: self = .array(try container.decode([CloudValue].self, forKey: .a))
        case .o: self = .object(try container.decode([String: CloudValue].self, forKey: .o))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .null: break
        case .bool(let value): try container.encode(value, forKey: .b)
        case .int(let value): try container.encode(value, forKey: .i)
        case .double(let value): try container.encode(value, forKey: .d)
        case .string(let value): try container.encode(value, forKey: .s)
        case .data(let value): try container.encode(value, forKey: .x)
        case .array(let value): try container.encode(value, forKey: .a)
        case .object(let value): try container.encode(value, forKey: .o)
        }
    }
}

extension CloudValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: CloudValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, CloudValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public struct CloudField: Sendable, Hashable, Codable {
    public var value: CloudValue
    public var hlc: HLC

    public init(value: CloudValue, hlc: HLC) {
        self.value = value
        self.hlc = hlc
    }

    private enum CodingKeys: String, CodingKey { case value = "v", hlc = "h" }
}

public struct CloudDocument: Sendable, Hashable, Codable {
    public var fields: [String: CloudField]
    public var deletedAt: HLC?

    public init(fields: [String: CloudField] = [:], deletedAt: HLC? = nil) {
        self.fields = fields
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey { case fields = "f", deletedAt = "d" }

    public var version: HLC? {
        let stamps = fields.values.map(\.hlc) + (deletedAt.map { [$0] } ?? [])
        return stamps.max()
    }

    public var isDeleted: Bool {
        guard let deletedAt else { return false }
        return fields.values.allSatisfy { $0.hlc < deletedAt }
    }

    public var values: [String: CloudValue] {
        guard !isDeleted else { return [:] }
        return fields.compactMapValues { $0.value == .null ? nil : $0.value }
    }
}

enum CloudCanonical {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest(_ document: CloudDocument) throws -> Data {
        let encoded = try encode(document)
        return Data(SHA256.hash(data: encoded).prefix(16))
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
