import Foundation
import MailModel
import OpenHumanCore

enum FakeRelatedMatch {
    static let limit = 20

    static let synonyms: [String: [String]] = [
        "retreat": ["offsite"],
        "offsite": ["retreat"],
        "receipt": ["order confirmation", "invoice"],
        "invoice": ["receipt", "bill"],
        "bill": ["invoice"],
        "postmortem": ["write-up", "retrospective"],
        "write-up": ["postmortem"],
        "retrospective": ["postmortem"],
        "trip": ["travel", "flight"],
        "journey": ["travel", "trip"],
        "recruiting": ["hiring"],
        "candidates": ["hiring"],
        "meal": ["dinner"],
    ]

    static func queries(_ text: String) -> [String] {
        guard !text.lowercased().contains("rfc822msgid:") else { return [] }
        let tokens = tokenize(text)
        var result: [String] = []
        for (index, token) in tokens.enumerated() {
            guard let word = freeTextWord(token), let alternatives = synonyms[word] else { continue }
            for alternative in alternatives {
                var replaced = tokens
                replaced[index] = alternative.contains(where: { !$0.isLetter && !$0.isNumber }) ? "\"\(alternative)\"" : alternative
                let query = replaced.joined(separator: " ")
                if !result.contains(query) { result.append(query) }
            }
        }
        return result
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for c in text {
            if c == "\"" { inQuote.toggle() }
            if c.isWhitespace, !inQuote {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func freeTextWord(_ token: String) -> String? {
        guard !token.contains(":"), !token.contains("\""), !token.contains("("), !token.contains(")"),
              !token.hasPrefix("-"), token != "OR", token != "AND" else { return nil }
        let word = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
        return word.count >= 3 ? word : nil
    }
}

extension State {
    mutating func relatedEntries(_ text: String, account: AccountID, excluding lexical: Set<ThreadKey>) -> [WindowEntry] {
        guard relatedSearchMatches else { return [] }
        var seen = lexical
        var hits: [SearchHitInfo] = []
        for query in FakeRelatedMatch.queries(text) {
            guard let found = try? searchEntries(query, accounts: [account]) else { continue }
            for hit in found where seen.insert(hit.row.id).inserted { hits.append(hit) }
        }
        hits.sort { ($0.row.lastMessageAt, $0.row.id.rowID) > ($1.row.lastMessageAt, $1.row.id.rowID) }
        return hits.prefix(FakeRelatedMatch.limit).map {
            WindowEntry(sortAt: $0.row.lastMessageAt, key: $0.row.id, match: .related)
        }
    }
}
