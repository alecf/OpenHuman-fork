import Foundation
import MailFakes
import MailFeatures
import MailModel
import Observation
import OpenHumanCore
import Synchronization
@testable import OpenHumanMail

@MainActor
func untilObserved(_ condition: @escaping @MainActor () -> Bool) async {
    await PhoneObservation.wait(for: condition)
}

@MainActor
func loadedPhone(_ environment: AppEnvironment = .fake(corpus: .small)) async -> PhoneMail {
    let phone = PhoneMail(environment: environment)
    phone.start()
    await untilObserved { phone.list?.state == .loaded && phone.list?.rows.isEmpty == false }
    return phone
}

func inInbox(_ store: FakeMailStore, _ key: ThreadKey) async throws -> Bool {
    for try await window in store.threadWindow(.system(.inbox), account: key.account, limit: 1_000) {
        return window.rows.contains { $0.id == key }
    }
    return false
}

final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var held: [CheckedContinuation<Void, Never>] = []
        var watchers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var arrivals: Int { state.withLock { $0.arrivals } }
    var isOpen: Bool { state.withLock { $0.isOpen } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (watchers, open) = state.withLock { s -> ([CheckedContinuation<Void, Never>], Bool) in
                s.arrivals += 1
                let watchers = s.watchers
                s.watchers = []
                if !s.isOpen { s.held.append(continuation) }
                return (watchers, s.isOpen)
            }
            for watcher in watchers { watcher.resume() }
            if open { continuation.resume() }
        }
    }

    func arrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { s -> Bool in
                if s.arrivals > 0 { return true }
                s.watchers.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.held = [] }
            return s.held
        }
        for continuation in held { continuation.resume() }
    }
}

final class HeldCommands: MailCommanding {
    let store: FakeMailStore
    let gate: Gate

    init(_ store: FakeMailStore, gate: Gate) {
        self.store = store
        self.gate = gate
    }

    func apply(_ command: MailCommand) async throws -> UndoToken {
        await gate.pass()
        return try await store.apply(command)
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? { try await store.undo(token) }
    func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int) { try await store.createDraft(input) }
    func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int {
        try await store.updateDraft(key, fields, expectedVersion: expectedVersion)
    }
    func flushDraft(_ key: DraftKey) async throws { try await store.flushDraft(key) }
    func discardDraft(_ key: DraftKey) async throws { try await store.discardDraft(key) }
    func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws { try await store.setReviewState(key, state) }
    func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws {
        try await store.resolveDraftConflict(key, resolution)
    }
    func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken { try await store.send(key, undoWindow: undoWindow) }
    func cancelSend(_ token: SendToken) async throws -> Bool { try await store.cancelSend(token) }
    func sendNow(_ token: SendToken) async throws -> Bool { try await store.sendNow(token) }
    func scheduleSend(_ key: DraftKey, at: Date) async throws { try await store.scheduleSend(key, at: at) }
    func cancelScheduledSend(_ key: DraftKey) async throws { try await store.cancelScheduledSend(key) }
    func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey? {
        try await store.fetchDraftNow(account, gmailDraftID: gmailDraftID)
    }
    func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey? {
        try await store.fetchThreadNow(account, gmailThreadID: gmailThreadID)
    }
    func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken {
        try await store.createLabel(account, name: name, applyTo: applyTo)
    }
    func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo { try await store.upsertSnippet(snippet) }
    func deleteSnippet(_ id: SnippetInfo.ID) async throws { try await store.deleteSnippet(id) }
    func recordSnippetUse(_ id: SnippetInfo.ID) async throws { try await store.recordSnippetUse(id) }
    func unsubscribe(_ key: MessageKey) async throws { try await store.unsubscribe(key) }
    func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey { try await store.upsertSplit(split) }
    func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws { try await store.deleteSplit(account, key) }
    func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws { try await store.reorderSplits(account, order) }
    func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws { try await store.dismissFailedOperation(id) }
}

@MainActor
func heldEnvironment(_ gate: Gate, corpus: FakeCorpus = .small) -> (AppEnvironment, FakeMailStore) {
    let store = FakeMailStore(corpus: corpus, options: FakeMailStore.Options())
    let environment = AppEnvironment(data: store, commands: HeldCommands(store, gate: gate), accounts: store,
                                     settings: store, isFake: true)
    return (environment, store)
}
