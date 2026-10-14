import Testing
@testable import MailUI

struct SearchQueryTokensTests {
    static let fixtures: [(String, [String], String)] = [
        ("from:dana ", ["from:dana"], ""),
        ("from:dana", [], "from:dana"),
        ("from:dana subject:budget q4", ["from:dana", "subject:budget"], "q4"),
        ("subject:\"q4 budget\" notes", ["subject:\"q4 budget\""], "notes"),
        ("subject:\"q4 budget notes", [], "subject:\"q4 budget notes"),
        ("-from:dana has:attachment ", ["-from:dana", "has:attachment"], ""),
        ("from:a OR from:b", ["from:a"], "OR from:b"),
        ("(from:a OR to:b) x", [], "(from:a OR to:b) x"),
        ("subject:(dinner movie) x", ["subject:(dinner movie)"], "x"),
        ("from:josé.núñez@example.com ", ["from:josé.núñez@example.com"], ""),
        ("label:\"Team Notes\" is:unread ", ["label:\"Team Notes\"", "is:unread"], ""),
        ("foo:bar baz", [], "foo:bar baz"),
        ("from: dana", [], "from: dana"),
        ("hello from:dana ", [], "hello from:dana "),
        ("FROM:Dana ", ["FROM:Dana"], ""),
        ("from:dana    to:theo  x", ["from:dana", "to:theo"], "x"),
        ("", [], ""),
    ]

    @Test(arguments: fixtures.indices)
    func splitsTheLeadingOperators(_ i: Int) {
        let (query, tokens, rest) = Self.fixtures[i]
        let parts = SearchQueryTokens.split(query)
        #expect(parts.tokens.map(\.raw) == tokens, "tokens of “\(query)”")
        #expect(parts.rest == rest, "text after the pills of “\(query)”")
    }

    @Test(arguments: fixtures.indices)
    func joiningGivesTheQueryBack(_ i: Int) {
        let query = Self.fixtures[i].0
        let parts = SearchQueryTokens.split(query)
        let joined = SearchQueryTokens.join(parts.tokens, rest: parts.rest)
        let squeezed = { (s: String) in s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
        #expect(squeezed(joined) == squeezed(query))
        #expect(SearchQueryTokens.split(joined).tokens == parts.tokens, "stable")
    }

    @Test func pillsShowAndSpeakTheirParts() throws {
        let label = try #require(SearchQueryTokens.split("label:\"Team Notes\" ").tokens.first)
        #expect(label.displayName == "label:" && label.displayValue == "Team Notes")
        #expect(label.spokenLabel == "label Team Notes, search filter")
        let from = try #require(SearchQueryTokens.split("-from:Michael x").tokens.first)
        #expect(from.isNegated && from.displayName == "−from:")
        #expect(from.spokenLabel == "not from Michael, search filter")
        let long = try #require(SearchQueryTokens.split("from:averyveryverylongname@example-company.com ").tokens.first)
        #expect(long.shortValue.count == 28 && long.shortValue.contains("…") && long.shortValue.hasSuffix("company.com"))
        let older = try #require(SearchQueryTokens.split("older_than:2d ").tokens.first)
        #expect(older.spokenLabel == "older than 2d, search filter")
    }

    @Test func backspaceInAnEmptyFieldReopensTheLastPill() {
        #expect(SearchQueryTokens.reopeningLast("from:dana to:theo ") == "from:dana to:theo")
        #expect(SearchQueryTokens.split("from:dana to:theo").rest == "to:theo", "the last pill is text again")
        #expect(SearchQueryTokens.reopeningLast("from:dana ") == "from:dana")
        #expect(SearchQueryTokens.reopeningLast("from:dana x") == nil, "text after the pills: ⌫ edits it")
        #expect(SearchQueryTokens.reopeningLast("hello") == nil, "no pill")
        #expect(SearchQueryTokens.reopeningLast("") == nil)
    }
}
