import Foundation
import Synchronization
#if canImport(os)
import os
#endif

public struct Log: Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case sync, queue, scheduler, gmail, oauth, store, cli, app, ai, links
        case calendar
        case keychain
    }

    public let category: Category

    #if canImport(os)
    private let logger: Logger
    #endif

    public init(_ category: Category) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: OHIdentifiers.logSubsystem, category: category.rawValue)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { emit(.notice, message()) }
    public func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private enum Level: String { case debug, info, notice, error }

    private func emit(_ level: Level, _ message: String) {
        let text = Log.redact(message)
        if let mirror = Log.mirror.withLock({ $0 }) {
            mirror(Record(date: Date(), category: category, level: level.rawValue, message: text))
        }
        #if canImport(os)
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        #else
        guard level != .debug else { return }
        let line = "[\(OHIdentifiers.logSubsystem):\(category.rawValue)] \(level.rawValue): \(text)\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    public struct Record: Sendable, Hashable {
        public let date: Date
        public let category: Category
        public let level: String
        public let message: String

        public init(date: Date, category: Category, level: String, message: String) {
            self.date = date
            self.category = category
            self.level = level
            self.message = message
        }
    }

    private static let mirror = Mutex<(@Sendable (Record) -> Void)?>(nil)

    public static func setMirror(_ sink: (@Sendable (Record) -> Void)?) {
        mirror.withLock { $0 = sink }
    }

    public static func redact(_ text: String) -> String {
        let prefixes = ["ya29.", "1//", "Bearer "]
        var out = ""
        var index = text.startIndex
        outer: while index < text.endIndex {
            for prefix in prefixes where text[index...].hasPrefix(prefix) {
                var end = text.index(index, offsetBy: prefix.count)
                while end < text.endIndex, isTokenCharacter(text[end]) { end = text.index(after: end) }
                if end > text.index(index, offsetBy: prefix.count) {
                    out += prefix == "Bearer " ? "Bearer <redacted>" : "<redacted>"
                    index = end
                    continue outer
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return redactingAddresses(out)
    }

    static func redactingAddresses(_ text: String) -> String {
        guard text.contains("@") || text.contains("%40") else { return text }
        let chars = Array(text)
        var out = ""
        var copied = 0
        var i = 0
        while i < chars.count {
            let separator = chars[i] == "@" ? 1
                : (chars[i] == "%" && i + 2 < chars.count && chars[i + 1] == "4" && chars[i + 2] == "0") ? 3 : 0
            guard separator > 0 else {
                i += 1
                continue
            }
            var start = i
            while start > copied, isAddressCharacter(chars[start - 1], local: true) { start -= 1 }
            var end = i + separator
            while end < chars.count, isAddressCharacter(chars[end], local: false) { end += 1 }
            while end > i + separator, chars[end - 1] == "." || chars[end - 1] == "-" { end -= 1 }
            let host = chars[(i + separator)..<end]
            if start < i, host.contains("."), host.first != "." {
                out += String(chars[copied..<start]) + "<email>"
                copied = end
                i = end
            } else {
                i += separator
            }
        }
        out += String(chars[copied...])
        return out
    }

    private static func isAddressCharacter(_ c: Character, local: Bool) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        switch v {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return (local ? "._%+-" : ".-").contains(c)
        }
    }

    private static func isTokenCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        switch v {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return "-._~+/=".contains(c)
        }
    }
}
