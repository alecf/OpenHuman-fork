import Foundation
import MailModel
import OpenHumanCore

public struct SnippetContext: Sendable {
    public var recipient: EmailAddress?
    public var myName: String?
    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var values: [String: String]

    public init(recipient: EmailAddress? = nil, myName: String? = nil, now: Date = Date(),
                calendar: Calendar = .current, locale: Locale = .current, values: [String: String] = [:]) {
        self.recipient = recipient
        self.myName = myName
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.values = values
    }
}

public struct SnippetReplacement: Hashable, Sendable {
    public let range: Range<Int>
    public let text: String
    public let name: String?
    public let isResolved: Bool
}

public struct SnippetExpansion: Hashable, Sendable {
    public let text: String
    public let unresolved: [Range<Int>]
}

public enum SnippetExpander {
    public static func variableNames(in text: String) -> [String] {
        var seen = Set<String>()
        return tokens(in: text).compactMap(\.name).filter { seen.insert($0).inserted }
    }

    public static func replacements(in text: String, variables: [SnippetVariableInfo] = [],
                                    context: SnippetContext) -> [SnippetReplacement] {
        let defaults = Dictionary(variables.compactMap { v in v.defaultValue.map { (v.name, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        return tokens(in: text).map { token in
            guard let name = token.name else {
                return SnippetReplacement(range: token.range, text: token.literal, name: nil, isResolved: true)
            }
            if let value = value(of: name, context: context, defaults: defaults), !value.isEmpty {
                return SnippetReplacement(range: token.range, text: value, name: name, isResolved: true)
            }
            return SnippetReplacement(range: token.range, text: name, name: name, isResolved: false)
        }
    }

    public static func expand(_ text: String, variables: [SnippetVariableInfo] = [],
                              context: SnippetContext) -> SnippetExpansion {
        let utf16 = Array(text.utf16)
        var out: [UInt16] = []
        var unresolved: [Range<Int>] = []
        var cursor = 0
        for r in replacements(in: text, variables: variables, context: context) {
            out.append(contentsOf: utf16[cursor..<r.range.lowerBound])
            let start = out.count
            out.append(contentsOf: Array(r.text.utf16))
            if !r.isResolved { unresolved.append(start..<out.count) }
            cursor = r.range.upperBound
        }
        out.append(contentsOf: utf16[cursor...])
        return SnippetExpansion(text: String(decoding: out, as: UTF16.self), unresolved: unresolved)
    }

    public static func unfilledPlaceholders(in text: String) -> [String] {
        variableNames(in: text)
    }

    public static func phrases(in text: String) -> [String] {
        let u = Array(text.utf16)
        let open = utf16Unit("{"), close = utf16Unit("}"), backslash = utf16Unit("\\"), newline = utf16Unit("\n")
        var result: [String] = []
        var seen = Set<String>()
        var i = 0
        while i < u.count {
            guard u[i] == open else { i += 1; continue }
            if i > 0, u[i - 1] == backslash { i += 1; continue }
            if i + 1 < u.count, u[i + 1] == open { i += 2; continue }
            var j = i + 1
            while j < u.count, j - i <= 61, u[j] != close, u[j] != open, u[j] != newline { j += 1 }
            guard j < u.count, u[j] == close, j > i + 1, !(j + 1 < u.count && u[j + 1] == close) else {
                i += 1
                continue
            }
            let phrase = String(decoding: u[(i + 1)..<j], as: UTF16.self)
            if !phrase.trimmingCharacters(in: .whitespaces).isEmpty, seen.insert(phrase).inserted { result.append(phrase) }
            i = j + 1
        }
        return result
    }

    struct Token: Hashable {
        let range: Range<Int>
        let name: String?
        var literal = "{{"
    }

    static func tokens(in text: String) -> [Token] {
        let u = Array(text.utf16)
        let open = utf16Unit("{"), close = utf16Unit("}"), backslash = utf16Unit("\\")
        var result: [Token] = []
        var i = 0
        while i + 1 < u.count {
            if u[i] == backslash, i + 2 < u.count, u[i + 1] == open, u[i + 2] == open {
                result.append(Token(range: i..<(i + 3), name: nil))
                i += 3
                continue
            }
            if u[i] == backslash, u[i + 1] == open {
                result.append(Token(range: i..<(i + 2), name: nil, literal: "{"))
                i += 2
                continue
            }
            guard u[i] == open, u[i + 1] == open else { i += 1; continue }
            var j = i + 2
            while j < u.count, j - i < 70, u[j] != close, u[j] != open { j += 1 }
            if j + 1 < u.count, u[j] == close, u[j + 1] == close {
                let name = String(decoding: u[(i + 2)..<j], as: UTF16.self)
                if isValidName(name) {
                    result.append(Token(range: i..<(j + 2), name: name))
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
        return result
    }

    public static func isValidName(_ name: String) -> Bool {
        if dateOffset(name) != nil { return true }
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func dateOffset(_ name: String) -> Int? {
        guard name.hasPrefix("date"), name.count > 5 else { return nil }
        let rest = name.dropFirst(4)
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let digits = rest.dropFirst()
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), let n = Int(digits), n <= 3650 else {
            return nil
        }
        return sign == "+" ? n : -n
    }

    static func value(of name: String, context: SnippetContext, defaults: [String: String]) -> String? {
        if let typed = context.values[name] { return typed }
        if let offset = dateOffset(name) {
            let day = context.calendar.date(byAdding: .day, value: offset, to: context.now) ?? context.now
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: context.locale)
            style.timeZone = context.calendar.timeZone
            return day.formatted(style.weekday(.abbreviated))
        }
        let parts = nameParts(context.recipient)
        switch name {
        case "first_name": return parts.first
        case "last_name": return parts.last
        case "full_name": return parts.full
        case "my_name": return context.myName.flatMap { $0.isEmpty ? nil : $0 }
        default: return defaults[name]
        }
    }

    static func nameParts(_ recipient: EmailAddress?) -> (first: String?, last: String?, full: String?) {
        guard let recipient else { return (nil, nil, nil) }
        let name = recipient.name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        if let name, !name.isEmpty {
            let ordered: [String]
            if name.contains(",") {
                ordered = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.reversed()
                    .filter { !$0.isEmpty }
            } else {
                ordered = [name]
            }
            let words = ordered.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
            return (words.first, words.count > 1 ? words.last : nil, words.joined(separator: " "))
        }
        let local = recipient.email.split(separator: "@").first.map(String.init) ?? recipient.email
        let first = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).first.map(String.init) ?? local
        return (first.prefix(1).uppercased() + first.dropFirst(), nil, nil)
    }
}

func utf16Unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
