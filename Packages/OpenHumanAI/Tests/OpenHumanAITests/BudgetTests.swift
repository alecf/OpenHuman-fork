import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct TokenHeuristicTests {
    @Test func latinIsBytesOverThreeRoundedUp() {
        #expect(TokenHeuristic.count("") == 0)
        #expect(TokenHeuristic.count("abc") == 1)
        #expect(TokenHeuristic.count("abcd") == 2)
        #expect(TokenHeuristic.count(String(repeating: "a", count: 300)) == 100)
        #expect(TokenHeuristic.count("é") == 1)
        #expect(TokenHeuristic.count("\u{1F600}") == 2)
    }

    @Test func cjkIsOneTokenPerScalar() {
        #expect(TokenHeuristic.count("日本語") == 3)
        #expect(TokenHeuristic.count("한국어") == 3)
        #expect(TokenHeuristic.count("ひらがな") == 4)
        #expect(TokenHeuristic.count("日本abc") == 2 + 1)
    }

    @Test func tallyMatchesCount() {
        var tally = TokenHeuristic.Tally()
        let pieces = ["Hello ", "wörld ", "日本", " and more text"]
        for piece in pieces { tally.add(piece) }
        #expect(tally.tokens == TokenHeuristic.count(pieces.joined()))
    }
}

@Suite struct ContextBudgeterTests {
    @Test func formulaUsesRuntimeContextAndMargin() throws {
        #expect(try ContextBudgeter.inputBudget(contextTokens: 1_000, policyInputCap: nil, fixedTokens: 100, reservedOutput: 200) == 600)
        #expect(try ContextBudgeter.inputBudget(contextTokens: 1_000, policyInputCap: 500, fixedTokens: 100, reservedOutput: 200) == 500)
        #expect(ContextBudgeter.safetyMargin(contextTokens: 2_049) == 205)
    }

    @Test func unknownContextUsesPolicyCapOrIsUnusable() throws {
        #expect(try ContextBudgeter.inputBudget(contextTokens: nil, policyInputCap: 300, fixedTokens: 100, reservedOutput: 200) == 300)
        #expect(throws: AIError.unavailable(.other("context size unknown"))) {
            try ContextBudgeter.inputBudget(contextTokens: nil, policyInputCap: nil, fixedTokens: 1, reservedOutput: 1)
        }
    }

    @Test func overflowAndShrink() throws {
        #expect(throws: AIError.contextOverflow(counted: 1_000, limit: 1_000)) {
            try ContextBudgeter.inputBudget(contextTokens: 1_000, policyInputCap: nil, fixedTokens: 700, reservedOutput: 200)
        }
        let shrunk = try ContextBudgeter.inputBudget(
            contextTokens: 1_000, policyInputCap: nil, fixedTokens: 100, reservedOutput: 200,
            shrink: AIPolicy.overflowShrinkFactor)
        #expect(shrunk == 450)
    }
}

@Suite struct ChunkerTests {
    static func fitsChars(_ limit: Int) -> (String) async -> Bool { { $0.count <= limit } }

    @Test func splitsOnParagraphsAndReconstructs() async throws {
        let paragraphs = (0..<12).map { "Paragraph \($0) " + String(repeating: "word ", count: 20 + $0) }
        let text = paragraphs.joined(separator: "\n\n")
        let pieces = try await Chunker.split(text, fits: Self.fitsChars(400))
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= 400 })
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.hasPrefix("Paragraph") })
    }

    @Test func fallsBackToSentencesWordsAndCharacters() async throws {
        let sentences = String(repeating: "This is one sentence. ", count: 40)
        let bySentence = try await Chunker.split(sentences, fits: Self.fitsChars(100))
        #expect(bySentence.allSatisfy { $0.count <= 100 && $0.hasPrefix("This") })
        #expect(bySentence.joined() == sentences)

        let words = String(repeating: "lorem ", count: 200)
        let byWord = try await Chunker.split(words, fits: Self.fitsChars(50))
        #expect(byWord.allSatisfy { $0.count <= 50 })
        #expect(byWord.joined() == words)

        let giant = String(repeating: "x", count: 1_000)
        let byCharacter = try await Chunker.split(giant, fits: Self.fitsChars(64))
        #expect(byCharacter.allSatisfy { $0.count <= 64 })
        #expect(byCharacter.joined() == giant)
    }

    @Test func impossibleBudgetThrows() async {
        let error = await aiError { _ = try await Chunker.split("abc", fits: { _ in false }) }
        #expect(error == .contextOverflow(counted: 1, limit: 0))
    }

    @Test func truncateCutsAtSentenceWithMarker() async throws {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let cut = try await Chunker.truncate(text, fits: Self.fitsChars(60))
        #expect(cut == "First sentence here. Second sentence here.\n[truncated]")
        #expect(try await Chunker.truncate("short", fits: Self.fitsChars(50)) == "short")
    }
}

@Suite struct ExcerptWindowTests {
    @Test func picksTheWindowWithMostKeywordHits() {
        let filler = String(repeating: "lorem ipsum dolor ", count: 60)
        let body = filler + "The budget for the offsite is approved, budget owner is Dana. " + filler
        let keywords = ExcerptWindow.keywords(in: "What is the budget for the offsite?")
        #expect(keywords == ["budget", "offsite"])
        let excerpt = ExcerptWindow.best(in: body, keywords: keywords)
        #expect(excerpt.contains("budget for the offsite"))
        #expect(excerpt.count <= AIPolicy.askInboxExcerptCharacters + 2)
        #expect(ExcerptWindow.best(in: "short body", keywords: keywords) == "short body")
    }
}
