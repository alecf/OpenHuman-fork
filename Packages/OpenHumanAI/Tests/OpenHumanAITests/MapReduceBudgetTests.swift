import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct MapReduceBudgetTests {
    static let contextSizes = [2_048, 3_000, 4_096, 8_192, 16_384, 32_768]
    static let policyCaps = [1_500, 4_000, 32_000]

    static func verboseProvider(_ capabilities: AICapabilities) -> ScriptedProvider {
        ScriptedProvider(capabilities: capabilities) { request, _ in
            .text(String(repeating: "word ", count: request.output.maxTokens * 2), chunkSize: 64)
        }
    }

    static func engine(_ features: DefaultAIFeatures, _ provider: any AIProvider, _ capabilities: AICapabilities)
        -> Engine
    {
        Engine(
            provider: provider, capabilities: capabilities, modelVersion: "v", settings: AISettings(), feature: .summarize,
            workload: .interactive, threadKey: "t")
    }

    @Test(arguments: contextSizes.map { Optional($0) } + [nil])
    func planStaysWithinBudget(contextTokens: Int?) async throws {
        let capabilities = AICapabilities.fake(contextTokens: contextTokens, policyInputCap: contextTokens == nil ? 4_000 : nil)
        let provider = Self.verboseProvider(capabilities)
        let features = makeFeatures([provider])
        let engine = Self.engine(features, provider, capabilities)
        let thread = SyntheticThreads.thread(messages: 30)
        let nonce = Untrusted.makeNonce()

        let plan = try await features.planSummary(thread, engine: engine, nonce: nonce, shrink: 1)
        guard case .mapReduce(let steps) = plan else {
            Issue.record("a 30-message synthetic thread should need map-reduce at \(String(describing: contextTokens))")
            return
        }
        for step in steps {
            let used = TokenHeuristic.count(Untrusted.render(step.parts, nonce: nonce))
            #expect(used <= step.budget)
        }
        for (index, message) in thread.messages.enumerated() {
            let chunks = steps.filter { $0.messageIndex == index }.map { $0.parts[1].text }
            #expect(!chunks.isEmpty)
            #expect(chunks.joined().filter { !$0.isWhitespace } == message.bodyText.filter { !$0.isWhitespace })
        }

        let worst = OutputGuard.cap(String(repeating: "word ", count: 400), maxTokens: AIPolicy.reservedChunkSummaryTokens).text
        let items = steps.map { UntrustedPart(kind: .summary, id: "\($0.parts[1].id).\($0.chunkIndex + 1)", text: worst) }
        let probe = try await features.prepare(
            .summarizeReduce, engine: engine, nonce: nonce, trusted: [], untrusted: [],
            output: .text(maxTokens: AIPolicy.reservedReduceTokens), shrink: 1)
        let subject = features.subjectPart(thread)
        var level = items
        var rounds = 0
        while true {
            let groups = try await features.reduceGroups(level, subject: subject, engine: engine, nonce: nonce, budget: probe.budget)
            for group in groups {
                #expect(group.count <= AIPolicy.reduceGroupSize)
                #expect(TokenHeuristic.count(Untrusted.render([subject] + group, nonce: nonce)) <= probe.budget)
            }
            if groups.count <= 1 { break }
            #expect(groups.count < level.count)
            level = groups.map { _ in UntrustedPart(kind: .summary, id: "r", text: worst + worst) }
            rounds += 1
            if rounds > 10 {
                Issue.record("reduce does not converge")
                break
            }
        }
    }

    @Test(arguments: contextSizes)
    func everyRequestFitsTheRuntimeContext(contextTokens: Int) async throws {
        let capabilities = AICapabilities.fake(contextTokens: contextTokens)
        let provider = Self.verboseProvider(capabilities)
        let features = makeFeatures([provider])
        let events = try await collect(features.summarize(SyntheticThreads.thread(messages: 30)))
        #expect(!summaryText(events).isEmpty)
        let requests = provider.requests
        #expect(requests.contains { $0.task == .summarizeChunk })
        #expect(requests.last?.task == .reduce)
        for request in requests {
            let used = untrustedTokens(request)
            #expect(used <= (try independentBudget(request, capabilities: capabilities)))
            #expect(
                fixedTokens(request) + used + request.output.maxTokens
                    + ContextBudgeter.safetyMargin(contextTokens: contextTokens) <= contextTokens)
            #expect(RequestInspector.problems(in: request).isEmpty, "\(RequestInspector.problems(in: request))")
            if request.task == .reduce {
                #expect(request.untrusted.filter { $0.kind == .summary }.count <= AIPolicy.reduceGroupSize)
            }
        }
        let mapped = Set(requests.filter { $0.task == .summarizeChunk }.compactMap { $0.untrusted.last?.id })
        #expect(mapped.count == 30)
    }

    @Test(arguments: policyCaps)
    func unknownContextUsesThePolicyCap(cap: Int) async throws {
        let capabilities = AICapabilities.fake(contextTokens: nil, policyInputCap: cap)
        let provider = Self.verboseProvider(capabilities)
        let features = makeFeatures([provider])
        _ = try await collect(features.summarize(SyntheticThreads.thread(messages: 30)))
        #expect(!provider.requests.isEmpty)
        for request in provider.requests {
            #expect(untrustedTokens(request) <= cap)
            #expect(RequestInspector.problems(in: request).isEmpty)
        }
    }

    @Test func unknownContextWithoutCapIsUnusable() async {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: nil, policyInputCap: nil))
        let features = makeFeatures([provider])
        let error = await aiError { _ = try await collect(features.summarize(SyntheticThreads.short())) }
        #expect(error == .unavailable(.other("context size unknown")))
        #expect(provider.requests.isEmpty)
    }

    @Test func tooSmallContextFailsWithoutCallingTheModel() async {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 600))
        let features = makeFeatures([provider])
        let error = await aiError { _ = try await collect(features.summarize(SyntheticThreads.short())) }
        guard case .contextOverflow = error else {
            Issue.record("expected contextOverflow, got \(String(describing: error))")
            return
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func newMessageAddsOneMapCall() async throws {
        let capabilities = AICapabilities.fake(contextTokens: 4_096)
        let provider = Self.verboseProvider(capabilities)
        let features = makeFeatures([provider])
        var thread = SyntheticThreads.thread(messages: 30, longEvery: 0)
        thread.messages = thread.messages.enumerated().map { index, message in
            var copy = message
            if index == 10 { copy.bodyText = "Short note for message eleven." }
            return copy
        }
        _ = try await collect(features.summarize(thread))
        let firstMaps = provider.requests.filter { $0.task == .summarizeChunk }.count
        #expect(firstMaps == 30)
        provider.reset()

        var next = thread
        next.messages.append(
            AIMessageInput(
                messageKey: "m31", from: "Dana Lee", date: Date(timeIntervalSince1970: 1_790_200_000),
                bodyText: "One more thing: can we move the call to Monday?"))
        _ = try await collect(features.summarize(next))
        #expect(provider.requests.filter { $0.task == .summarizeChunk }.count == 1)
        #expect(provider.requests.last?.task == .reduce)
    }
}
