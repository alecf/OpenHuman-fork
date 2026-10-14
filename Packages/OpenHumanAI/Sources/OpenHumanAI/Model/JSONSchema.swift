import Foundation

public indirect enum JSONSchema: Sendable, Hashable {
    case object(properties: [String: JSONSchema], required: [String])
    case array(items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil)
    case string(maxLength: Int? = nil, enumValues: [String]? = nil)
    case integer(minimum: Int? = nil, maximum: Int? = nil)
    case boolean

    public var jsonValue: JSONValue {
        switch self {
        case .object(let properties, let required):
            var props: [String: JSONValue] = [:]
            for (name, schema) in properties { props[name] = schema.jsonValue }
            return .object([
                "type": .string("object"),
                "properties": .object(props),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": .bool(false),
            ])
        case .array(let items, let minItems, let maxItems):
            var out: [String: JSONValue] = ["type": .string("array"), "items": items.jsonValue]
            if let minItems { out["minItems"] = .int(minItems) }
            if let maxItems { out["maxItems"] = .int(maxItems) }
            return .object(out)
        case .string(let maxLength, let enumValues):
            var out: [String: JSONValue] = ["type": .string("string")]
            if let maxLength { out["maxLength"] = .int(maxLength) }
            if let enumValues { out["enum"] = .array(enumValues.map(JSONValue.string)) }
            return .object(out)
        case .integer(let minimum, let maximum):
            var out: [String: JSONValue] = ["type": .string("integer")]
            if let minimum { out["minimum"] = .int(minimum) }
            if let maximum { out["maximum"] = .int(maximum) }
            return .object(out)
        case .boolean:
            return .object(["type": .string("boolean")])
        }
    }

    public var jsonString: String { jsonValue.canonicalString }

    public func validate(_ value: JSONValue, path: String = "$") -> [String] {
        switch (self, value) {
        case (.object(let properties, let required), .object(let fields)):
            var errors: [String] = []
            for name in required where fields[name] == nil { errors.append("\(path).\(name): missing") }
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                guard let schema = properties[name] else {
                    errors.append("\(path).\(name): not allowed")
                    continue
                }
                errors += schema.validate(field, path: "\(path).\(name)")
            }
            return errors
        case (.array(let items, let minItems, let maxItems), .array(let elements)):
            var errors: [String] = []
            if let minItems, elements.count < minItems { errors.append("\(path): \(elements.count) items < \(minItems)") }
            if let maxItems, elements.count > maxItems { errors.append("\(path): \(elements.count) items > \(maxItems)") }
            for (index, element) in elements.enumerated() { errors += items.validate(element, path: "\(path)[\(index)]") }
            return errors
        case (.string(let maxLength, let enumValues), .string(let text)):
            var errors: [String] = []
            if let maxLength, text.count > maxLength { errors.append("\(path): longer than \(maxLength)") }
            if let enumValues, !enumValues.contains(text) { errors.append("\(path): not one of the allowed values") }
            return errors
        case (.integer(let minimum, let maximum), _):
            guard let number = value.integerValue else { return ["\(path): expected integer"] }
            var errors: [String] = []
            if let minimum, number < minimum { errors.append("\(path): below \(minimum)") }
            if let maximum, number > maximum { errors.append("\(path): above \(maximum)") }
            return errors
        case (.boolean, .bool):
            return []
        case (.object, _): return ["\(path): expected object"]
        case (.array, _): return ["\(path): expected array"]
        case (.string, _): return ["\(path): expected string"]
        case (.boolean, _): return ["\(path): expected boolean"]
        }
    }
}

public enum JSONValue: Sendable, Hashable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var integerValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 1e15: return Int(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    public var canonicalString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
