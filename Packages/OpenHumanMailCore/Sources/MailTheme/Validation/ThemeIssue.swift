import Foundation

public struct ThemeIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable {
        case warning, refused
    }

    public enum Code: String, Sendable, Hashable {
        case tooLarge, invalidJSON, notAnObject, tooDeep, tooManyKeys, stringTooLong
        case unknownFormat, unsupportedVersion, missingField
        case invalidID, reservedID, duplicateID, invalidName, invalidAppearance, invalidAccentID
        case unknownKey, wrongType, invalidValue, clamped, injection
        case unknownReference, incompatibleReference, referenceCycle, referenceTooDeep
        case unknownParent, extendsTooDeep, extendsCycle, unknownAccent, accentShortIDConflict
        case missingToken, contrast, contrastRefused, fontMissing, unreadable, themeUnavailable
    }

    public let severity: Severity
    public let code: Code
    public let path: String
    public let message: String

    public init(_ severity: Severity, _ code: Code, path: String = "", _ message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }

    static func warning(_ code: Code, _ path: String, _ message: String) -> ThemeIssue { .init(.warning, code, path: path, message) }
    static func refused(_ code: Code, _ path: String, _ message: String) -> ThemeIssue { .init(.refused, code, path: path, message) }
}

extension Array where Element == ThemeIssue {
    public var isRefused: Bool { contains { $0.severity == .refused } }
    public var warnings: [ThemeIssue] { filter { $0.severity == .warning } }
}
