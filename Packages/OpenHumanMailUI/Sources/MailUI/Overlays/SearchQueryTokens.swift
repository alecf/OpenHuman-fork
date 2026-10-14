import Foundation
import MailTheme
import SwiftUI

struct SearchQueryToken: Hashable, Sendable {
    let name: String
    let value: String
    let isNegated: Bool

    var raw: String { (isNegated ? "-" : "") + name + ":" + value }

    var displayValue: String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { return String(value.dropFirst().dropLast()) }
        return value
    }

    var shortValue: String {
        let value = displayValue
        guard value.count > 28 else { return value }
        return String(value.prefix(16)) + "…" + String(value.suffix(11))
    }

    var displayName: String { (isNegated ? "−" : "") + name.lowercased() + ":" }

    var spokenLabel: String {
        let words = name.lowercased().replacingOccurrences(of: "_", with: " ")
        return (isNegated ? "not " : "") + words + " " + displayValue + ", search filter"
    }
}

public enum SearchQueryTokens {
    static let known: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "label", "has", "is", "in", "before", "after", "older", "newer",
        "older_than", "newer_than", "filename", "category", "list", "larger", "smaller", "deliveredto",
    ]

    static func split(_ text: String) -> (tokens: [SearchQueryToken], rest: String) {
        var tokens: [SearchQueryToken] = []
        var index = text.startIndex
        while true {
            var start = index
            while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
            guard let (token, end) = token(in: text, at: start), end < text.endIndex, text[end].isWhitespace else {
                return (tokens, tokens.isEmpty ? text : String(text[start...]))
            }
            tokens.append(token)
            index = end
        }
    }

    static func join(_ tokens: [SearchQueryToken], rest: String) -> String {
        guard !tokens.isEmpty else { return rest }
        return tokens.map(\.raw).joined(separator: " ") + " " + rest
    }

    public static func reopeningLast(_ text: String) -> String? {
        let parts = split(text)
        guard parts.rest.isEmpty, let last = parts.tokens.last else { return nil }
        return join(Array(parts.tokens.dropLast()), rest: last.raw)
    }

    private static func token(in text: String, at start: String.Index) -> (SearchQueryToken, String.Index)? {
        var i = start
        var negated = false
        if i < text.endIndex, text[i] == "-" {
            negated = true
            i = text.index(after: i)
        }
        let nameStart = i
        while i < text.endIndex, text[i].isLetter || text[i] == "_" { i = text.index(after: i) }
        guard i > nameStart, i < text.endIndex, text[i] == ":" else { return nil }
        let name = String(text[nameStart..<i])
        guard known.contains(name.lowercased()) else { return nil }
        i = text.index(after: i)
        guard i < text.endIndex, !text[i].isWhitespace else { return nil }
        let valueStart = i
        switch text[i] {
        case "\"":
            i = text.index(after: i)
            while i < text.endIndex, text[i] != "\"" { i = text.index(after: i) }
            guard i < text.endIndex, text.distance(from: valueStart, to: i) > 1 else { return nil }
            i = text.index(after: i)
        case "(":
            var depth = 0
            repeat {
                if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            } while depth > 0 && i < text.endIndex
            guard depth == 0 else { return nil }
        default:
            while i < text.endIndex, !text[i].isWhitespace, text[i] != "(", text[i] != ")" { i = text.index(after: i) }
            if i < text.endIndex, !text[i].isWhitespace { return nil }
        }
        let token = SearchQueryToken(name: name, value: String(text[valueStart..<i]), isNegated: negated)
        return (token, i)
    }
}

struct SearchTokenPill: View {
    let token: SearchQueryToken
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text(token.displayName)
                .fontWeight(.semibold)
                .foregroundStyle(theme.accentText.color)
                .fixedSize()
            Text(token.shortValue)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
        }
        .fixedSize()
        .font(theme.typeLabel.swiftUIFont)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: theme.radiusPill).fill(theme.accentFill.color.opacity(0.16)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(token.spokenLabel)
    }
}
