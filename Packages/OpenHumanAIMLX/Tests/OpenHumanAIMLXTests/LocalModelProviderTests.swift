import CryptoKit
import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIMLX
@testable import OpenHumanAIModelStore
@testable import OpenHumanAITesting

final class InMemoryTransport: DownloadTransport, @unchecked Sendable {
    let body: Data
    init(body: Data) { self.body = body }

    func fetch(url: URL, to destination: URL, resumeFrom offset: Int64, maxBytes: Int64, progress: @Sendable (Int64) -> Void) async throws {
        try body.write(to: destination)
        progress(Int64(body.count))
    }
}

final class FakeRuntime: LocalModelRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _unloads = 0
    let contextSize: Int?
    let answer: @Sendable (String, String) -> String

    init(contextSize: Int? = 8192, answer: @escaping @Sendable (String, String) -> String = { _, _ in "A fake answer." }) {
        self.contextSize = contextSize
        self.answer = answer
    }

    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    fileprivate func recordUnload() { lock.withLock { _unloads += 1 } }

    func load(modelDirectory: URL, manifest: ModelManifest) async throws -> any LocalModelSession {
        lock.withLock { _loads += 1 }
        return FakeSession(owner: self)
    }
}

struct FakeSession: LocalModelSession {
    let owner: FakeRuntime
    var contextSize: Int? { owner.contextSize }
    func countTokens(_ text: String) async -> Int? { text.split(separator: " ").count }
    func generate(system: String, input: String, maxTokens: Int, temperature: Double?) -> AsyncThrowingStream<String, Error> {
        let text = owner.answer(system, input)
        return AsyncThrowingStream { continuation in
            for piece in text.split(separator: " ", omittingEmptySubsequences: false) { continuation.yield(String(piece) + " ") }
            continuation.finish()
        }
    }
    func unload() async { owner.recordUnload() }
}

func makeManifest(declaredContext: Int? = 2048) -> (ModelManifest, Data) {
    let body = Data("fake weights".utf8)
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    let manifest = ModelManifest(
        id: "tiny-test", displayName: "Tiny test model", sourceURL: URL(string: "https://models.example.test/tiny")!,
        revision: "rev1", files: [.init(path: "w.bin", url: URL(string: "https://models.example.test/tiny/w.bin")!, sizeBytes: Int64(body.count), sha256: digest)],
        license: "test", format: .mlx, declaredContextTokens: declaredContext)
    return (manifest, body)
}

func makeRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mlx-test-\(UUID().uuidString)") }

func installed(_ manifest: ModelManifest, _ body: Data, root: URL) async -> ModelStore {
    let store = ModelStore(rootDirectory: root, transport: InMemoryTransport(body: body), freeSpace: { _ in 100 << 30 })
    for await _ in await store.download(manifest, confirmedSizeBytes: manifest.totalBytes) {}
    return store
}

func collectText(_ stream: AsyncThrowingStream<AIEvent, Error>) async throws -> String {
    var text = ""
    for try await event in stream { if case .textDelta(let delta) = event { text += delta } }
    return text
}

func sampleRequest() -> AIRequest {
    AIRequest(
        task: .summarize, promptID: PromptID("summarize.thread", version: 1), system: "Summarize.", trusted: [],
        untrusted: [UntrustedPart(kind: .emailBody, id: "m1", text: "Synthetic text.")], output: .text(maxTokens: 50),
        nonce: "Ab12Cd34Ef56")
}

@Suite struct LocalModelProviderTests {
    @Test func availabilityFollowsTheStoreAndTheOptIn() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = ModelStore(rootDirectory: root, transport: InMemoryTransport(body: body), freeSpace: { _ in 100 << 30 })
        let enabled = Flag(false)
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: FakeRuntime(), allowsModelLoading: { enabled.value })
        #expect(provider.id == "local.tiny-test")
        #expect(await provider.availability() == .unavailable(reason: .modelNotDownloaded(sizeBytes: Int64(body.count))))

        for await _ in await store.download(manifest, confirmedSizeBytes: manifest.totalBytes) {}
        #expect(await provider.availability() == .unavailable(reason: .disabledBySettings))
        enabled.value = true
        #expect(await provider.availability() == .available)
        #expect(await provider.modelVersion() == "tiny-test@rev1")
    }

    @Test func nothingLoadsWithoutTheExplicitOptIn() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let runtime = FakeRuntime()
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: runtime)
        await #expect(throws: AIError.unavailable(.disabledBySettings)) { _ = try await collectText(provider.run(sampleRequest())) }
        #expect(runtime.loads == 0)
        #expect(await !provider.isLoaded)
    }

    @Test func theDefaultRuntimeNeverLoadsAnything() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let provider = LocalModelProvider(manifest: manifest, store: store, allowsModelLoading: { true })
        await #expect(throws: AIError.unavailable(.other("This build does not include the local model runtime"))) {
            _ = try await collectText(provider.run(sampleRequest()))
        }
    }

    @Test func loadsLazilyOnceAndStreams() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let runtime = FakeRuntime(answer: { system, input in "SYS[\(system)] IN[\(input.contains("Synthetic text.") ? "ok" : "missing")]" })
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: runtime, allowsModelLoading: { true })
        #expect(runtime.loads == 0)
        let first = try await collectText(provider.run(sampleRequest()))
        #expect(first.contains("SYS[Summarize.]"))
        #expect(first.contains("IN[ok]"))
        _ = try await collectText(provider.run(sampleRequest()))
        #expect(runtime.loads == 1)
        #expect(await provider.isLoaded)
    }

    @Test func contextSizeComesFromTheRuntimeAndTheManifestIsOnlyAFallback() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest(declaredContext: 2048)
        let store = await installed(manifest, body, root: root)
        let runtime = FakeRuntime(contextSize: 16_384)
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: runtime, allowsModelLoading: { true })
        #expect(await provider.capabilities().contextTokens == 2048)
        #expect(await provider.capabilities().tokenCounting == .heuristic)
        _ = try await collectText(provider.run(sampleRequest()))
        #expect(await provider.capabilities().contextTokens == 16_384)
        #expect(await provider.capabilities().tokenCounting == .exact)
        #expect(await provider.countTokens("one two three") == 3)
        #expect(await provider.capabilities().dataLocation == .onDevice)
    }

    @Test func memoryPressureUnloadsTheModel() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let runtime = FakeRuntime()
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: runtime, allowsModelLoading: { true })
        _ = try await collectText(provider.run(sampleRequest()))
        #expect(await provider.isLoaded)
        await provider.handleMemoryPressure()
        #expect(await !provider.isLoaded)
        #expect(runtime.unloads == 1)
        _ = try await collectText(provider.run(sampleRequest()))
        #expect(runtime.loads == 2)
    }

    @Test func anIdleModelUnloadsAfterTheTimeout() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let runtime = FakeRuntime()
        let provider = LocalModelProvider(
            manifest: manifest, store: store, runtime: runtime, allowsModelLoading: { true }, idleTimeout: .milliseconds(150))
        _ = try await collectText(provider.run(sampleRequest()))
        var unloaded = false
        for _ in 0..<500 {
            if runtime.unloads == 1 { unloaded = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(unloaded)
        #expect(await !provider.isLoaded)
    }

    @Test func theMemoryPressureSourceCanBeStartedAndDropped() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, body) = makeManifest()
        let store = await installed(manifest, body, root: root)
        let provider = LocalModelProvider(manifest: manifest, store: store, runtime: FakeRuntime(), allowsModelLoading: { true })
        provider.startMonitoringMemoryPressure()
        provider.startMonitoringMemoryPressure()
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite struct PromptedClassifierTests {
    private func input() -> ClassificationInput {
        ClassificationInput.make(
            from: AIThreadInput(
                threadKey: "t", subject: "Invoice 42",
                messages: [AIMessageInput(messageKey: "m1", from: "Billing <b@example.com>", date: Date(timeIntervalSince1970: 1_790_000_000), bodyText: "Your invoice is attached.", subject: "Invoice 42")]))
    }

    @Test func buildsTheTriageRequestAndValidatesTheAnswer() async throws {
        let scripted = ScriptedProvider(id: "local.fake", respond: { _, _ in .text(#"Sure: {"category":"receipt","priority":1,"reason":"An invoice."}"#) })
        let classifier = try #require(PromptedClassifier(wrapping: scripted))
        #expect(classifier.id == "local.fake.classifier")
        let result = try await classifier.classify(input())
        #expect(result.category == .receipt)
        #expect(result.providerID == classifier.id)

        let request = try #require(scripted.requests.first)
        #expect(request.task == .classify)
        #expect(request.output.schema == OutputGuard.triageSchema)
        #expect(request.untrusted.count == 3)
        #expect(!request.system.contains("Invoice 42"))
        #expect(Untrusted.render(request.untrusted, nonce: request.nonce).contains("Invoice 42"))
    }

    @Test func nonJSONAnswersAreRejected() async throws {
        let scripted = ScriptedProvider(id: "local.fake", respond: { _, _ in .text("I think it is a receipt.") })
        let classifier = try #require(PromptedClassifier(wrapping: scripted))
        await #expect(throws: AIError.invalidOutput("The classifier did not return JSON.")) { _ = try await classifier.classify(input()) }
    }

    @Test func aSuspiciousReasonIsBlankedButTheCategoryStays() async throws {
        let scripted = ScriptedProvider(id: "local.fake", respond: { _, _ in .text(#"{"category":"other","priority":3,"reason":"see user_instruction"}"#) })
        let classifier = try #require(PromptedClassifier(wrapping: scripted))
        let result = try await classifier.classify(input())
        #expect(result.reason.isEmpty)
        #expect(result.category == .other)
    }

    @Test func aProviderThatSendsDataOffTheMacIsNeverWrapped() {
        let remote = FakeAIProvider(id: .agentClaude, capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        #expect(PromptedClassifier(wrapping: remote, dataLocation: .thirdParty(vendor: "Anthropic")) == nil)
    }

    @Test func aRemoteProviderPassedAsOnDeviceIsStillRefusedAtRunTime() async throws {
        let remote = FakeAIProvider(id: .agentClaude, capabilities: .fake(dataLocation: .thirdParty(vendor: "Anthropic")))
        let classifier = try #require(PromptedClassifier(wrapping: remote))
        await #expect(throws: AIError.unavailable(.onDeviceOnly)) { _ = try await classifier.classify(input()) }
    }
}
