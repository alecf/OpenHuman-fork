import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct PromptExampleNameTests {
    static let copyable = [
        "Dana", "Robin", "Acme", "Sarah", "Sam", "Alex", "Priya", "Maria", "John", "Jane", "Mike", "Bob", "Alice",
        "Chris", "launch review", "Oct 3", "oct 14", "switching topics",
    ]
    @Test func noShippedPromptContainsACopyableExampleName() throws {
        let library = try PromptLibrary.loadBundled()
        #expect(!library.templates.isEmpty)
        for template in library.templates.values {
            for name in Self.copyable {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
                let found = template.body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                #expect(!found, "\(template.id) contains the example \"\(name)\"")
            }
        }
    }

    @Test func theEditedPromptsWereBumped() throws {
        let library = try PromptLibrary.loadBundled()
        #expect(try library.template(named: "summarize.line").id.version >= 3)
        #expect(try library.template(named: "summarize.chunk").id.version >= 2)
        #expect(try library.template(named: "search.plan").id.version >= 2)
        #expect(try library.template(named: "schedule.extract").id.version >= 2)
    }
}

@Suite struct RewriteBudgetTests {
    @Test func theAnswerGetsTheWindowMinusInputHeadroomAndMargin() {
        #expect(AIPolicy.generationOutputBudget(contextTokens: 8_192, inputTokens: 100) == 6_672)
        #expect(AIPolicy.generationOutputBudget(contextTokens: 8_192, inputTokens: 0) == 6_772)
        #expect(AIPolicy.generationOutputBudget(contextTokens: 8_192, inputTokens: 100) > 64)
    }

    @Test func aBiggerInputLeavesASmallerAnswerAndNeverBelowTheMinimum() {
        let small = AIPolicy.generationOutputBudget(contextTokens: 4_096, inputTokens: 100)
        let big = AIPolicy.generationOutputBudget(contextTokens: 4_096, inputTokens: 2_000)
        #expect(big < small)
        #expect(AIPolicy.generationOutputBudget(contextTokens: 4_096, inputTokens: 100_000) == AIPolicy.generationMinimumOutputTokens)
        #expect(AIPolicy.generationOutputBudget(contextTokens: 100, inputTokens: 0) == AIPolicy.generationMinimumOutputTokens)
    }

    @Test func anUnknownContextUsesTheFixedFallback() {
        #expect(AIPolicy.generationOutputBudget(contextTokens: nil, inputTokens: 50)
                == AIPolicy.generationUnknownContextOutputTokens)
    }

    @Test func theBudgetPlusTheInputAlwaysFitsTheWindow() {
        for context in [2_048, 4_096, 8_192, 32_768] {
            for input in [0, 10, 500, 1_500] {
                let output = AIPolicy.generationOutputBudget(contextTokens: context, inputTokens: input)
                if output > AIPolicy.generationMinimumOutputTokens {
                    #expect(output + input + AIPolicy.rewriteFixedHeadroomTokens
                            + ContextBudgeter.safetyMargin(contextTokens: context) <= context)
                }
            }
        }
    }

    @Test func aGeneratedAnswerFromAnEmptyDraftIsNotCappedTo64() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Fine.", chunkSize: 4) }
        _ = try await collect(makeFeatures([provider]).rewrite("", instruction: "Write a short thank-you", context: nil))
        #expect((provider.requests.first?.output.maxTokens ?? 0) > 5_000)
    }
}

@Suite struct AnswerTrimTests {
    @Test func cutsBackToTheLastCompleteSentence() {
        #expect(AnswerTrim.toLastCompleteSentence("Hello there. I can meet on the sec\u{2026}") == "Hello there.")
        #expect(AnswerTrim.toLastCompleteSentence("One. Two! Three? Four and\u{2026}") == "One. Two! Three?")
        #expect(AnswerTrim.toLastCompleteSentence("He said \"yes.\" Then we wen\u{2026}") == "He said \"yes.\"")
    }

    @Test func keepsTextWithoutAFinishedSentence() {
        #expect(AnswerTrim.toLastCompleteSentence("Hello and welc\u{2026}") == "Hello and welc\u{2026}")
        #expect(AnswerTrim.toLastCompleteSentence("Version 3.5 is out and we\u{2026}") == "Version 3.5 is out and we\u{2026}")
    }

    @Test func aFinishedSentenceBeforeTheEllipsisIsKept() {
        #expect(AnswerTrim.toLastCompleteSentence("All done.\u{2026}") == "All done.")
    }
}

@Suite struct PromptPlainnessTests {
    @Test func noShippedPromptHasAWorkedExampleOrAWordLimit() throws {
        let library = try PromptLibrary.loadBundled()
        for template in library.templates.values {
            let body = template.body
            #expect(body.range(of: "for example", options: .caseInsensitive) == nil, "\(template.id) has a worked example")
            #expect(body.range(of: "such as \"", options: .caseInsensitive) == nil, "\(template.id) has a quoted example")
            #expect(body.range(of: #"at most \d+ (words|sentences)"#, options: .regularExpression) == nil,
                    "\(template.id) has a word limit")
            #expect(body.range(of: #"(\d+|one|two|three|four|five|ten|twenty)\s*(-\s*\w+\s*)?(words|sentences)\b"#,
                               options: [.regularExpression, .caseInsensitive]) == nil,
                    "\(template.id) has a word or sentence count")
            #expect(body.range(of: #"\be\.g\.|\bi\.e\.|\blike this\b|\bexample:"#,
                               options: [.regularExpression, .caseInsensitive]) == nil,
                    "\(template.id) has an example")
        }
    }
}
