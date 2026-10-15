import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class AIFixture {
    let store: FakeMailStore
    let recorder: RecordingCommands
    let env: AppEnvironment
    let router: AppRouter
    let compose: ComposeManager
    let center: AICenter
    let registry: ProviderRegistry
    let pasteboard = RecordingPasteboard()
    static let work = AccountID(1)

    let appSettings: HeldSettings

    init(safeMode: SafeModeInfo = .normal, settings: AISettings = AISettings(), providers: [any AIProvider]? = nil,
         flags: FeatureFlags = FeatureFlags(), withAI: Bool = true, calendar: (any CalendarProviding)? = nil,
         traces: (any AITraceStore)? = nil) {
        store = FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                              options: .init(remoteAck: .immediate, heldSends: .manual, safeMode: safeMode, now: { fixedNow }))
        recorder = RecordingCommands(store)
        registry = ProviderRegistry(providers: providers ?? [ScriptedProvider()])
        center = AICenter.make(registry: registry, settings: AISettingsBox(store: InMemoryAISettingsStore(settings)),
                               traces: traces)
        center.pasteboard = pasteboard
        appSettings = HeldSettings(store)
        env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: appSettings, isFake: true,
                             featureFlags: flags, ai: withAI ? center : nil, calendar: calendar)
        router = env.router
        compose = env.compose
        compose.timing = ComposeTiming(autosaveDelay: .milliseconds(1), discardWindow: .seconds(6), now: { fixedNow },
                                       sleep: { duration in if duration == .milliseconds(1) { return } })
        router.start()
    }

    func loaded() async {
        await eventually { router.active != nil && router.list?.state == .loaded && router.accounts.count == 2 }
    }

    @discardableResult
    func run(_ id: ActionID, in session: ComposeSession) async -> Bool {
        await env.actions.run(id, source: .keyboard, host: session)
    }

    @discardableResult
    func run(_ id: ActionID) async -> Bool {
        await env.actions.run(id, source: .keyboard, host: router)
    }

    func newMessage(_ text: String, selection: Range<Int>? = nil) throws -> (ComposeSession, FakeEditor) {
        let session = try #require(compose.openNew(placement: .modal))
        let editor = FakeEditor(session: session, text: text, selection: selection)
        return (session, editor)
    }

    func thread(minimumMessages: Int = 1, maximumMessages: Int = .max, lastFromMe: Bool = false) async throws -> ThreadKey {
        let rows = try await store.threadPage(.system(.inbox), account: Self.work, after: nil, limit: 1_000).rows
        let me = try #require(router.accounts.first { $0.id == Self.work }?.account)
        for row in rows {
            guard let detail = await AIThreadLoader.first(store.threadDetail(row.id)) ?? nil,
                  (minimumMessages...maximumMessages).contains(detail.messages.count), let last = detail.messages.last
            else { continue }
            if me.isMe(last.from?.email ?? "") == lastFromMe { return row.id }
        }
        Issue.record("no conversation with \(minimumMessages)+ messages (last from me: \(lastFromMe))")
        throw CancellationError()
    }

    func reply(_ thread: ThreadKey) async throws -> (ComposeSession, FakeEditor) {
        let session = try #require(compose.openReply(thread, mode: .reply))
        await session.settle()
        return (session, FakeEditor(session: session, text: "", selection: 0..<0))
    }
}

@MainActor
final class FakeEditor: ComposeTextEditing {
    var text: String
    var selection: Range<Int>
    private(set) var replacements: [(range: Range<Int>, text: String)] = []
    private(set) var focusCount = 0
    private(set) var caretPlacements: [Int] = []
    weak var session: ComposeSession?

    init(session: ComposeSession, text: String, selection: Range<Int>?) {
        self.text = text
        self.selection = selection ?? ((text as NSString).length..<(text as NSString).length)
        self.session = session
        session.editor = self
        if !text.isEmpty { session.updateBody(doc(text)) }
    }

    var editorText: String { text }
    var editorSelection: Range<Int> { selection }

    func replaceText(in range: Range<Int>, with new: String) -> Bool {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return false }
        text = ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: new)
        selection = range.lowerBound..<(range.lowerBound + (new as NSString).length)
        replacements.append((range, new))
        session?.updateBody(doc(text))
        return true
    }

    func focusEditor() { focusCount += 1 }

    func placeCaret(at offset: Int) {
        let at = min(max(0, offset), (text as NSString).length)
        selection = at..<at
        caretPlacements.append(at)
    }

    func type(_ typed: String) {
        _ = replaceText(in: selection, with: typed)
        let end = selection.upperBound
        selection = end..<end
    }
}

final class HeldSettings: SettingsPort, @unchecked Sendable {
    private let base: any SettingsPort
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ base: any SettingsPort) { self.base = base }

    func hold() { lock.withLock { held = true } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> { base.observe(key) }

    func get<V>(_ key: AppSettingKey<V>) async throws -> V {
        if key.name == AppSettings.signatureOnReplies.name {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wait = lock.withLock { () -> Bool in
                    guard held else { return false }
                    waiters.append(continuation)
                    return true
                }
                if !wait { continuation.resume() }
            }
        }
        return try await base.get(key)
    }

    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws { try await base.set(key, value) }
}

@MainActor
final class RecordingPasteboard: TextPasteboard {
    private(set) var copied: [String] = []
    func copy(_ text: String) { copied.append(text) }
}

extension AICapabilities {
    static func remote(_ vendor: String = "Anthropic") -> AICapabilities {
        .fake(contextTokens: nil, policyInputCap: 32_000, dataLocation: .thirdParty(vendor: vendor))
    }
}
