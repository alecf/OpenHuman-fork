import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

private let fixedNonce = "Nq7Rk2Vt9Wx4"

private func tracedFeatures(
    _ providers: [any AIProvider], settings: AISettings = AISettings(), sink: (any AITraceSink)?,
    clock: any AIClock = ManualAIClock(), cache: any AIResultCache = InMemoryAIResultCache(),
    ids: SequentialTraceIDs = SequentialTraceIDs()
) -> DefaultAIFeatures {
    DefaultAIFeatures(
        registry: ProviderRegistry(providers: providers), settings: { settings }, cache: cache, traces: sink,
        clock: clock, now: { fixedNow }, makeNonce: { fixedNonce }, makeTraceID: { ids.make() })
}

private func textFields(_ trace: AITraceRecord) -> [String] {
    [trace.systemText, trace.inputText, trace.outputText, trace.finalText, trace.errorText].compactMap { $0 }
}

@Suite struct AITraceTests {
    @Test func aRewriteKeepsThePromptInputAndOutputAsSentWithTimingFromTheClock() async throws {
        let clock = ManualAIClock()
        let provider = ClockedProvider(
            capabilities: .fake(contextTokens: 8_192), clock: clock,
            steps: [.advance(.milliseconds(120)), .text("Thanks, "), .advance(.milliseconds(30)), .text("see you Friday.")],
            usage: AIUsage(inputTokens: 210, outputTokens: 6))
        let sink = RecordingTraceSink()
        let features = tracedFeatures([provider], sink: sink, clock: clock)
        let events = try await collect(features.rewriteEvents("thx c u fri", instruction: "Make it friendlier", context: nil))

        let traces = await sink.traces
        #expect(traces.count == 1)
        let trace = try #require(traces.first)
        #expect(trace.feature == .rewrite && trace.task == .rewrite && trace.trigger == .user)
        #expect(trace.promptID == PromptID("rewrite.instruct", version: 3))
        #expect(trace.systemText?.contains("Task: rewrite the draft") == true)
        #expect(trace.systemText?.contains("<email_data nonce=\"\(AITraceRecord.nonceStandIn)\"") == true)
        #expect(trace.inputText?.contains("thx c u fri") == true)
        #expect(trace.inputText?.contains("Make it friendlier") == true)
        #expect(trace.inputParts.map(\.kind) == ["userInstruction", "draft"])
        #expect(trace.outputText == "Thanks, see you Friday." && trace.finalText == "Thanks, see you Friday.")
        #expect(trace.model == "clocked-1" && trace.providerName == "Clocked model")
        #expect(trace.latencyMilliseconds == 150 && trace.firstTokenMilliseconds == 120)
        #expect(trace.usage == AIUsage(inputTokens: 210, outputTokens: 6))
        #expect(trace.outcome == .completed && trace.cache == AITraceCacheUse.none && !trace.leftDevice)
        #expect(trace.createdAt == fixedNow && trace.parameters.outputLimit != nil)

        guard case .started(let provenance) = events.first, case .completed(let report) = events.last else {
            Issue.record("expected started first and completed last")
            return
        }
        #expect(provenance.traceID == trace.id && report.traceID == trace.id)
        #expect(provenance.feature == .rewrite && provenance.promptID == trace.promptID)
        #expect(report.model == "clocked-1" && report.latency == .milliseconds(150))
        #expect(report.firstToken == .milliseconds(120))
    }

    @Test func theNonceNeverReachesAStoredRecord() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { request, _ in
            .text("Echo \(request.nonce) done.")
        }
        let sink = RecordingTraceSink()
        let features = tracedFeatures([provider], sink: sink)
        _ = try await collect(features.rewriteEvents("draft", instruction: "fix", context: nil))
        let trace = try #require(await sink.traces.first)
        #expect(!textFields(trace).isEmpty)
        #expect(textFields(trace).allSatisfy { !$0.contains(fixedNonce) })
        #expect(trace.outputText == "Echo \(AITraceRecord.nonceStandIn) done.")
    }

    @Test func aCacheHitIsTracedWithoutCallingTheProvider() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("A short summary.") }
        let sink = RecordingTraceSink()
        let features = tracedFeatures([provider], sink: sink)
        let thread = SyntheticThreads.short()
        _ = try await collect(features.summarize(thread))
        let calls = provider.requests.count
        let second = try await collect(features.summarize(thread))
        #expect(provider.requests.count == calls)

        let traces = await sink.traces
        let first = try #require(traces.first)
        let hit = try #require(traces.last)
        #expect(first.cache == .miss && first.outcome == .completed)
        #expect(hit.cache == .hit && hit.outcome == .cached && hit.finalText == "A short summary.")
        #expect(hit.id != first.id)
        guard case .started(let provenance) = second.first else {
            Issue.record("expected started")
            return
        }
        #expect(provenance.fromCache && provenance.traceID == hit.id)
    }

    @Test func refusalsAndCancellationsAreRecordedWithTheirKind() async throws {
        let refusing = ScriptedProvider(capabilities: .fake(contextTokens: 8_192), responses: [.fail(.refused)])
        let sink = RecordingTraceSink()
        let error = await aiError {
            _ = try await collect(tracedFeatures([refusing], sink: sink).rewriteEvents("draft", instruction: "x", context: nil))
        }
        #expect(error == .refused)
        let refused = try #require(await sink.traces.last)
        #expect(refused.outcome == .failed && refused.errorKind == "refused" && refused.finalText == nil)

        let stopped = ScriptedProvider(capabilities: .fake(contextTokens: 8_192), responses: [.fail(.cancelled)])
        let cancelSink = RecordingTraceSink()
        _ = await aiError {
            _ = try await collect(tracedFeatures([stopped], sink: cancelSink).rewriteEvents("draft", instruction: "x", context: nil))
        }
        let cancelled = try #require(await cancelSink.traces.last)
        #expect(cancelled.outcome == .cancelled && cancelled.errorKind == "cancelled")
    }

    @Test func aSecretGateBlockIsAStepAndTheHiddenTextIsNotInTheFinalText() async throws {
        let provider = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities()) { _, _ in
            .text("Summary line one.\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n", chunkSize: 7)
        }
        let sink = RecordingTraceSink()
        let features = tracedFeatures([provider], settings: consenting([.agentClaude]), sink: sink)
        let error = await aiError { _ = try await collect(features.summarize(SyntheticThreads.short())) }
        guard case .outputBlocked = error else {
            Issue.record("expected outputBlocked, got \(String(describing: error))")
            return
        }
        let trace = try #require(await sink.traces.last)
        #expect(trace.steps.contains { $0.kind == .blockedBySecretGate })
        #expect(trace.finalText == "Summary line one.\n")
        #expect(trace.finalText?.contains("PRIVATE KEY") == false)
        #expect(trace.leftDevice && trace.outcome == .failed && trace.errorKind == "outputBlocked")
    }

    @Test func withoutASinkNothingIsRecordedAndTheFeatureStillWorks() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Done.") }
        let events = try await collect(tracedFeatures([provider], sink: nil).rewriteEvents("draft", instruction: "x", context: nil))
        guard case .completed(let report) = events.last else {
            Issue.record("expected completed")
            return
        }
        #expect(report.traceID != nil && report.model == "fake")
    }

    @Test func mapReduceStepsPointAtTheFinalSummary() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 4_096)) { _, _ in .text("Part summary.") }
        let sink = RecordingTraceSink()
        let features = tracedFeatures([provider], sink: sink)
        let events = try await collect(features.summarize(SyntheticThreads.thread(messages: 30)))
        let traces = await sink.traces
        guard case .completed(let report) = events.last, let rootID = report.traceID else {
            Issue.record("expected a completed report with a trace")
            return
        }
        let root = try #require(traces.first { $0.id == rootID })
        #expect(root.parentID == nil && root.task == .reduce)
        let steps = traces.filter { $0.id != rootID }
        #expect(steps.count >= 2)
        #expect(steps.allSatisfy { $0.parentID == rootID })
        #expect(Set(traces.map(\.id)).count == traces.count)
        guard case .started(let provenance) = events.first else {
            Issue.record("expected started")
            return
        }
        #expect(provenance.traceID == rootID)
    }

    @Test func aRepairedAnswerIsASecondTraceLinkedToTheFirst() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192), responses: [
            .text("not json"), .json(Data(replyJSON.utf8)),
        ])
        let sink = RecordingTraceSink()
        let result = try await tracedFeatures([provider], sink: sink)
            .replyOptionsResult(SyntheticThreads.short(), userName: "Robin")
        let traces = await sink.traces
        #expect(traces.count == 2)
        let first = try #require(traces.first)
        let repaired = try #require(traces.last)
        #expect(repaired.parentID == first.id && repaired.steps.contains { $0.kind == .repairedJSON })
        #expect(result.provenance.traceID == repaired.id && result.report.traceID == repaired.id)
    }
}

@Suite struct AITraceStorageTests {
    private func trace(_ index: Int, feature: AIFeature = .rewrite, minutesAgo: Double = 0, accounts: [String] = ["home"],
                       text: String = "Invented text") -> AITraceRecord
    {
        AITraceRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
            createdAt: fixedNow.addingTimeInterval(-minutesAgo * 60), feature: feature, task: .rewrite, trigger: .user,
            accountKeys: accounts, providerID: .fake, providerName: "Fake model", dataLocation: .onDevice,
            systemText: text, inputText: text, outputText: text, finalText: text, outcome: .completed)
    }

    @Test func retentionDropsOldTracesKeepsTheNewestPerFeatureAndFitsTheByteCap() {
        let rows = [
            trace(1, minutesAgo: 60 * 24 * 31), trace(2, minutesAgo: 3), trace(3, minutesAgo: 2), trace(4, minutesAgo: 1),
            trace(5, feature: .summarize, minutesAgo: 5),
        ]
        let byAge = AITraceSettings().retention.survivors(rows, now: fixedNow)
        #expect(Set(byAge.map(\.id)) == Set(rows.dropFirst().map(\.id)))

        let perFeature = AITraceRetention(keepFor: 86_400, perFeature: 2, maxBytes: .max).survivors(rows, now: fixedNow)
        #expect(perFeature.map(\.id) == [rows[3].id, rows[2].id, rows[4].id], "newest two rewrites, and the summary")

        let oneRow = rows[3].textBytes
        let bytes = AITraceRetention(keepFor: 86_400, perFeature: 500, maxBytes: oneRow * 2).survivors(rows, now: fixedNow)
        #expect(bytes.map(\.id) == [rows[3].id, rows[2].id])
    }

    @Test func theSinkHonoursTheSettingsAndCanKeepNoText() async throws {
        let store = InMemoryAITraceStore()
        let textless = AITraceSettings(includeText: false, disabledFeatures: [.summarize])
        let sink = StoreTraceSink(store: store, settings: { textless }, now: { fixedNow })
        await sink.record(trace(1))
        await sink.record(trace(2, feature: .summarize))
        await sink.amend(trace(1).id, finalText: "Shown text", steps: [AITraceStep(.flaggedSuspicious)])
        let kept = try await store.recent(limit: 10)
        #expect(kept.map(\.id) == [trace(1).id])
        #expect(kept.first.map(textFields) == [])
        #expect(kept.first?.steps.map(\.kind) == [.flaggedSuspicious])

        let disabled = AITraceSettings(enabled: false)
        let off = StoreTraceSink(store: store, settings: { disabled }, now: { fixedNow })
        await off.record(trace(3))
        #expect(try await store.trace(trace(3).id) == nil)
    }

    @Test func forgettingAnAccountRemovesEveryTraceThatTouchedIt() async throws {
        let retention = AITraceSettings().retention
        let store = InMemoryAITraceStore()
        try await store.append(trace(1, accounts: ["home"]), retention: retention, now: fixedNow)
        try await store.append(trace(2, accounts: ["work"]), retention: retention, now: fixedNow)
        try await store.append(trace(3, accounts: ["home", "work"]), retention: retention, now: fixedNow)
        try await store.forget(accountKey: "work")
        #expect(try await store.recent(limit: 10).map(\.id) == [trace(1).id])
        try await store.setRating(trace(1).id, rating: 1)
        #expect(try await store.trace(trace(1).id)?.rating == 1)
        try await store.deleteAll()
        #expect(try await store.recent(limit: 10).isEmpty)
    }

    @Test func traceSettingsDecodeTolerantlyAndDefaultToKeepingText() throws {
        let older = try JSONDecoder().decode(AISettings.self, from: Data(#"{"pccEnabled":true}"#.utf8))
        #expect(older.traces == AITraceSettings())
        #expect(older.traces.enabled && older.traces.includeText && !older.traces.allowExport)
        #expect(older.traces.keepDays == 30 && older.traces.perFeatureLimit == 500 && older.traces.maxBytes == 250_000_000)
        let partial = try JSONDecoder().decode(
            AISettings.self, from: Data(#"{"traces":{"keepDays":7,"includeText":"wrong"}}"#.utf8))
        #expect(partial.traces.keepDays == 7 && partial.traces.includeText)
        var changed = AISettings()
        changed.traces.disabledFeatures = [.classify]
        #expect(try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func dataLocationsRoundTripThroughTheirStoredForm() {
        for location in [AIDataLocation.onDevice, .appleCloud, .thirdParty(vendor: "Example vendor")] {
            #expect(AIDataLocation(traceValue: location.traceValue) == location)
        }
        #expect(AIDataLocation(traceValue: "elsewhere") == nil)
    }
}
