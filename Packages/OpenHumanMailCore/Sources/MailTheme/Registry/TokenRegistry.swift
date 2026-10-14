import Foundation

public struct TokenRegistry: Sendable {
    public enum Layer: String, Sendable, Hashable, Codable {
        case semantic, accent, base, component, reader
    }

    public enum ValueType: String, Sendable, Hashable, Codable {
        case color, shadow, number, typography, fontFamily, motion, duration, emailColors, percent
    }

    public enum DefaultValue: Sendable, Hashable, Decodable {
        case string(String)
        case number(Double)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let n = try? container.decode(Double.self) { self = .number(n) } else { self = .string(try container.decode(String.self)) }
        }
    }

    public struct Entry: Sendable, Hashable, Decodable {
        public let name: String
        public let layer: Layer
        public let type: ValueType
        public let path: [String]
        public let swift: String
        public let group: String?
        public let groupSwift: String?
        public let unit: String?
        public let min: Double?
        public let max: Double?
        public let css: String?
        public let `default`: DefaultValue?

        public var key: String { path.joined(separator: "/") }
    }

    public let entries: [Entry]
    private let byName: [String: Entry]
    private let byComponentName: [String: Entry]
    private let byKey: [String: Entry]
    private let interior: Set<String>

    public init(entries: [Entry]) {
        self.entries = entries
        var byName: [String: Entry] = [:]
        var byComponentName: [String: Entry] = [:]
        var byKey: [String: Entry] = [:]
        var interior = Set<String>()
        for entry in entries {
            if entry.layer == .component { byComponentName[entry.name] = entry } else { byName[entry.name] = entry }
            byKey[entry.key] = entry
            for n in 1..<entry.path.count { interior.insert(entry.path.prefix(n).joined(separator: "/")) }
        }
        self.byName = byName
        self.byComponentName = byComponentName
        self.byKey = byKey
        self.interior = interior
    }

    public func entry(named name: String) -> Entry? { byName[name] }

    public func component(named name: String) -> Entry? { byComponentName[name] }

    public func entry(at path: [String]) -> Entry? { byKey[path.joined(separator: "/")] }

    public func entry(forKey key: String) -> Entry? { byKey[key] }

    public func isSection(_ path: [String]) -> Bool { interior.contains(path.joined(separator: "/")) }

    private struct FileShape: Decodable {
        let format: String
        let formatVersion: Int
        let tokens: [Entry]
    }

    public static func decode(_ data: Data) -> TokenRegistry? {
        guard let shape = try? JSONDecoder().decode(FileShape.self, from: data),
              shape.format == "openhuman-token-registry", shape.formatVersion == 1 else { return nil }
        return TokenRegistry(entries: shape.tokens)
    }

    public static let v1: TokenRegistry = {
        guard let registry = decode(Data(BuiltinThemeSources.registry.utf8)) else {
            preconditionFailure("the embedded token registry does not decode (run Tools/ThemeCodegen)")
        }
        return registry
    }()
}
