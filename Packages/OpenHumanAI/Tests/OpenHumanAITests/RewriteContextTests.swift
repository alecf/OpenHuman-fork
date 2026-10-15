import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

private func message(_ index: Int, words: Int = 12) -> AIMessageInput {
    let body = "Message \(index): " + Array(repeating: "planning notes for the offsite", count: max(1, words / 5))
        .joined(separator: " ")
    return AIMessageInput(
        messageKey: "m\(index)", from: "Person \(index) <person\(index)@example.com>",
        date: fixedNow.addingTimeInterval(Double(index) * 3_600), bodyText: body)
}

private func conversation(_ count: Int, words: Int = 12, account: String? = "home") -> AIThreadInput {
    AIThreadInput(threadKey: "thread-offsite", subject: "Offsite plans", messages: (1...count).map { message($0, words: words) },
                  accountKey: account)
}

@Suite struct RewriteContextTests {
    @Test func aReplyRewriteSendsEveryMessageUpToTheOneBeingAnswered() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Sounds good.") }
        let features = makeFeatures([provider])
        let thread = try #require(conversation(4).upTo("m3"))
        _ = try await collect(features.rewrite("sure tues ok", instruction: "Make it friendlier", context: thread))
        let request = try #require(provider.requests.first)
        #expect(request.promptID == PromptID("rewrite.instruct", version: 3))
        #expect(request.untrusted.map(\.kind) == [.subject, .sender, .emailBody, .sender, .emailBody, .sender, .emailBody, .draft])
        #expect(request.untrusted.filter { $0.kind == .emailBody }.map(\.id) == ["m1", "m2", "m3"])
        #expect(request.untrusted.last?.text == "sure tues ok")
        #expect(!request.renderedInput().contains("Message 4:"))
        #expect(RequestInspector.problems(in: request).isEmpty)
        #expect(RequestInspector.leaks(in: request).isEmpty)
    }

    @Test func aThreadTooLongKeepsTheNewestMessagesTheDraftAndTheCachedSummary() async throws {
        let cache = InMemoryAIResultCache()
        let thread = conversation(10, words: 200)
        let roomy = ScriptedProvider(capabilities: .fake(contextTokens: 32_768)) { _, _ in .text("They agreed on a date.") }
        _ = try await collect(makeFeatures([roomy], cache: cache).summarize(thread))

        let tight = ScriptedProvider(capabilities: .fake(contextTokens: 2_048)) { _, _ in .text("Sounds good.") }
        let sink = RecordingTraceSink()
        let features = DefaultAIFeatures(
            registry: ProviderRegistry(providers: [tight]), settings: { AISettings() }, cache: cache, traces: sink,
            now: { fixedNow })
        _ = try await collect(features.rewrite("sure tues ok", instruction: "Make it friendlier", context: thread))
        let request = try #require(tight.requests.first)
        let bodies = request.untrusted.filter { $0.kind == .emailBody }.map(\.id)
        #expect(!bodies.isEmpty && bodies.count < 10)
        #expect(bodies.last == "m10", "the newest message is kept")
        #expect(!bodies.contains("m1"), "the oldest goes first")
        #expect(request.untrusted.contains { $0.kind == .summary && $0.text == "They agreed on a date." })
        #expect(request.untrusted.contains { $0.kind == .draft && $0.text == "sure tues ok" })
        #expect(untrustedTokens(request) <= (try independentBudget(request, capabilities: .fake(contextTokens: 2_048))))
        let trace = try #require(await sink.traces.last)
        #expect(trace.steps.map(\.kind).contains(.conversationShortened))
        #expect(trace.steps.map(\.kind).contains(.summaryUsedForConversation))
    }

    @Test func aThreadThatFitsIsSentWholeWithoutTheSummary() async throws {
        let cache = InMemoryAIResultCache()
        let thread = conversation(3)
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text(request.task == .summarize ? "A summary." : "Sounds good.")
        }
        let features = makeFeatures([provider], cache: cache)
        _ = try await collect(features.summarize(thread))
        provider.reset()
        _ = try await collect(features.rewrite("ok", instruction: "Friendlier", context: thread))
        let request = try #require(provider.requests.first)
        #expect(!request.untrusted.contains { $0.kind == .summary })
        #expect(request.untrusted.filter { $0.kind == .emailBody }.count == 3)
    }

    @Test func writingFromNotesUsesItsOwnPromptAndSendsNoEmptyDraft() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Tuesday works for me.") }
        let features = makeFeatures([provider])
        let events = try await collect(features.rewriteEvents(
            "  \n", instruction: "Write the email from these notes: confirm tuesday", context: conversation(2)))
        let request = try #require(provider.requests.first)
        #expect(request.promptID == PromptID("compose.write", version: 1))
        #expect(request.task == .rewrite)
        #expect(!request.untrusted.contains { $0.kind == .draft })
        #expect(request.untrusted.filter { $0.kind == .emailBody }.map(\.id) == ["m1", "m2"])
        #expect(request.system.contains("Task: write the email"))
        #expect(request.trusted.first == TrustedPart(kind: .userInstruction, text: "Write the email from these notes: confirm tuesday"))
        guard case .started(let provenance) = events.first else {
            Issue.record("expected started")
            return
        }
        #expect(provenance.promptID == PromptID("compose.write", version: 1))

        _ = try await collect(features.rewriteEvents("", instruction: "Write the email from these notes: hello", context: nil))
        let alone = try #require(provider.requests.last)
        #expect(alone.untrusted.isEmpty && alone.promptID.name == "compose.write")
    }

    @Test func anOnDeviceOnlyAccountStillSendsTheConversationOnlyOnTheDevice() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities())
        let system = ScriptedProvider(id: .appleSystem, capabilities: .fake(contextTokens: 8_192))
        let settings = consenting(
            [.agentClaude], AISettings(providerOrder: [.agentClaude, .appleSystem], onDeviceOnlyAccounts: ["work"]))
        let features = makeFeatures([claude, system], settings: settings)
        _ = try await collect(features.rewrite("draft", instruction: "fix", context: conversation(3, account: "work")))
        _ = try await collect(features.rewriteEvents("", instruction: "notes", context: conversation(3, account: "work")))
        #expect(claude.requests.isEmpty)
        #expect(system.requests.count == 2)
        #expect(system.requests.allSatisfy { $0.untrusted.contains { $0.kind == .emailBody } })
    }
}

@Suite struct AskInboxLimitsTests {
    private static func candidates(_ count: Int, characters: Int) -> [AIMessageInput] {
        (1...count).map { index in
            let filler = String(repeating: "The offsite budget review continues. ", count: characters / 37 + 1)
            return AIMessageInput(
                messageKey: "c\(index)", from: "Sender \(index) <s\(index)@example.com>",
                date: fixedNow.addingTimeInterval(Double(-index) * 3_600),
                bodyText: String(("Budget note \(index). " + filler).prefix(characters)), subject: "Budget \(index)")
        }
    }

    @Test func aLongAnswerThatFitsTheContextIsNotCut() async throws {
        let answer = Array(repeating: "The budget was approved in the planning review.", count: 120).joined(separator: " ")
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 16_384)) { _, _ in
            .text(answer + "\nSources: c1", chunkSize: 64)
        }
        let events = try await collect(makeFeatures([provider]).askInbox("offsite budget", candidates: Self.candidates(3, characters: 600)))
        let text = events.compactMap { if case .textDelta(let t) = $0 { return t } else { return nil } }.joined()
        #expect(TokenHeuristic.count(answer) > 300)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == answer)
        #expect(!events.contains { if case .completed(let report) = $0 { return report.truncated } else { return false } })
        let request = try #require(provider.requests.first)
        #expect(request.output.maxTokens > TokenHeuristic.count(answer))
    }

    @Test func wholeEmailsAreSentWhenTheyFit() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 16_384)) { _, _ in .text("Answer.\nSources: c1") }
        let candidates = Self.candidates(3, characters: 1_500)
        _ = try await collect(makeFeatures([provider]).askInbox("offsite budget", candidates: candidates))
        let request = try #require(provider.requests.first)
        #expect(request.untrusted.filter { $0.kind == .excerpt }.map(\.text) == candidates.map(\.bodyText))
    }

    @Test func excerptsGrowToFillTheRoomInsteadOfAFixedWidth() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Answer.\nSources: c1") }
        let candidates = Self.candidates(6, characters: 8_000)
        _ = try await collect(makeFeatures([provider]).askInbox("offsite budget", candidates: candidates))
        let request = try #require(provider.requests.first)
        let excerpts = request.untrusted.filter { $0.kind == .excerpt }
        #expect(excerpts.count == 6, "every candidate still fits")
        #expect(excerpts.allSatisfy { $0.text.count > AIPolicy.askInboxExcerptCharacters + 2 })
        #expect(excerpts.allSatisfy { $0.text.count < 8_000 })
        #expect(untrustedTokens(request) <= (try independentBudget(request, capabilities: .fake(contextTokens: 8_192))))
    }
}
