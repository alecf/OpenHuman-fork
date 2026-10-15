import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail

private let now = Date(timeIntervalSince1970: 1_791_000_000)

private func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>, where predicate: (T) -> Bool = { _ in true }) async throws -> T {
    for try await value in stream where predicate(value) { return value }
    throw CancellationError()
}

@Test(.timeLimit(.minutes(1))) func everyAccountGetsItsOwnStatusIncludingOneAddedLater() async throws {
    let store = try MailStore.openInMemoryForTesting()
    let work = try store.addAccount(email: "work@example.com", displayName: nil, scopes: ["gmail.modify"])
    let (engineStates, engine) = AsyncStream.makeStream(of: [AccountID: AccountConnectivity].self)
    var states = SyncSession.connectivity(engineStates, store: store).makeAsyncIterator()
    engine.yield([work: .online(syncing: false, lastSyncAt: nil)])
    var value = await states.next()
    while value?[work] == nil { value = await states.next() }
    #expect(value?.count == 1)

    let personal = try store.addAccount(email: "personal@example.com", displayName: nil, scopes: ["gmail.modify"])
    engine.yield([work: .online(syncing: false, lastSyncAt: nil), personal: .needsReauth])
    while value?[personal] != .needsReauth { value = await states.next() }
    #expect(value?[work] != nil && value?.count == 2)
    engine.finish()
}

@Test func everyAccountsBackfillLineIsPassedOn() {
    let work = AccountID(1), personal = AccountID(2)
    let running = SyncProgress(stage: .inbox, inboxSynced: 1_240, inboxTotal: 4_707, isRunning: true)
    let lines = SyncSession.lines([work: SyncProgress(), personal: running])
    #expect(lines.count == 1, "an account with nothing running has no line")
    #expect(lines[personal] == running.statusText && lines[personal] != nil)
}

@Test(.timeLimit(.minutes(1))) func aRefusedChangeIsListedWithItsCommandAndConversation() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now))
    let adapter = MailStoreAdapter(store: store)
    func inbox() throws -> [Int64] {
        try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10).items.map(\.ref.rowID.rawValue)
    }
    let row = try #require(try store.threadPage(view: .system(account, .inbox), after: nil, limit: 1).items.first)
    let receipt = try store.apply(.archive([row.ref]), origin: .app)
    #expect(try !inbox().contains(row.ref.rowID.rawValue), "out of the inbox at once")
    let op = try #require(receipt.operationIDs.first)
    try store.fail(op, code: "server_500", message: "synthetic", retryAt: nil)
    #expect(try inbox().contains(row.ref.rowID.rawValue), "the failure puts the conversation back")

    let failures = try await first(adapter.failedOperations(nil)) { !$0.isEmpty }
    let failure = try #require(failures.first)
    #expect(failure.id == op.rawValue && failure.account == account)
    #expect(failure.kind == "markDone", "the archive's label change reads back as the command")
    #expect(failure.threads.map(\.rowID) == [row.id.rawValue])
    #expect(failure.errorCode == "server_500")
    #expect(try await first(adapter.failedOperations(AccountID(9_999))).isEmpty, "another account's are left out")

    try store.dismissFailedOperation(op)
    _ = try await first(adapter.failedOperations(nil)) { $0.isEmpty }
}

@Test func theCommandIsReadBackFromTheGmailCall() {
    func kind(add: [String] = [], remove: [String] = [], names: [String] = []) -> String {
        MailStoreAdapter.failedKind(.modifyLabels(ids: [GmailMessageID("m1")], add: add.map { GmailLabelID($0) },
                                                  remove: remove.map { GmailLabelID($0) }, addNames: names))
    }
    #expect(kind(remove: ["INBOX"]) == "markDone")
    #expect(kind(add: ["INBOX"]) == "moveToInbox")
    #expect(kind(remove: ["UNREAD"]) == "markRead" && kind(add: ["UNREAD"]) == "markUnread")
    #expect(kind(add: ["STARRED"]) == "star" && kind(remove: ["STARRED"]) == "unstar")
    #expect(kind(add: ["SPAM"], remove: ["INBOX"]) == "markSpam" && kind(add: ["INBOX"], remove: ["SPAM"]) == "markNotSpam")
    #expect(kind(add: ["Label_1"]) == "modifyLabels" && kind(names: ["Synthetic"]) == "modifyLabels")
    #expect(MailStoreAdapter.failedKind(.trash(ids: [])) == "trash")
    #expect(MailStoreAdapter.failedKind(.sendDraft(draftID: DraftID("d1"))) == "sendDraft")
}

@Test(.timeLimit(.minutes(1))) func theComposersSnippetListFollowsTheStore() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    var list = MailStoreAdapter(store: store).snippets(account).makeAsyncIterator()
    let initial = try await list.next()
    #expect(initial?.contains { $0.id == "gap-s1" } == false)
    try store.upsertSnippet(SnippetItem(id: "gap-s1", name: "Synthetic thanks", bodyHTML: "<p>Thanks</p>", variables: [],
                                        useCount: 0))
    var next = try await list.next()
    while next?.contains(where: { $0.id == "gap-s1" }) != true { next = try await list.next() }
    try store.deleteSnippet(id: "gap-s1")
    while next?.contains(where: { $0.id == "gap-s1" }) == true { next = try await list.next() }
    #expect(next?.contains { $0.id == "gap-s1" } == false, "a delete shows too")
}

@Test(.timeLimit(.minutes(1))) func aLabelViewLoadsItsFirstScreenOncePerLaunch() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 2, now: now))
    let adapter = MailStoreAdapter(store: store, onDemand: .init(loadView: { _ in }))
    let label = GmailLabelID("Label_synthetic")
    _ = adapter.threadWindow(.label(label), account: account, limit: 10)
    _ = adapter.threadWindow(.label(label), account: account, limit: 10)
    _ = adapter.threadWindow(.system(.inbox), account: account, limit: 10)
    #expect(adapter.viewLoader?.openedViews == [.label(account, label)], "once, and the inbox is the sync's own")
    #expect(ViewLoader.loadsOnOpen(.label(label)) && ViewLoader.loadsOnOpen(.system(.trash)))
    #expect(!ViewLoader.loadsOnOpen(.system(.inbox)) && !ViewLoader.loadsOnOpen(.splitOther))
}
