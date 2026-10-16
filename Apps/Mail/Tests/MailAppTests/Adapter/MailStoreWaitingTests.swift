import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let now = Date(timeIntervalSince1970: 1_791_000_000)

private func firstThread(_ store: MailStore, _ account: AccountID) async throws -> ThreadKey {
    let data = MailStoreAdapter(store: store)
    let window = try await firstValue(data.threadWindow(.system(.inbox), account: account, limit: 20)) { !$0.rows.isEmpty }
    return try #require(window.rows.first).id
}

@Test(.timeLimit(.minutes(1))) func aChoiceIsStoredAndEachUndoPutsThePreviousOneBack() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 5, now: now))
    let thread = try await firstThread(store, account)
    let port = MailStoreWaiting(store: store)

    let first = try await port.setChoice(.waiting, for: thread)
    #expect(try WaitingReceipt(token: first).restore == nil, "there was no choice before")
    let second = try await port.setChoice(.notWaiting, for: thread)
    #expect(try WaitingReceipt(token: second).restore == .waiting)
    let probe = try store.setWaitingOverride(MailStoreWaiting.ref(thread), nil)
    #expect(probe == .notWaiting)
    _ = try store.setWaitingOverride(MailStoreWaiting.ref(thread), .notWaiting)

    let redo = try #require(try await port.undo(second))
    #expect(try WaitingReceipt(token: redo).restore == .notWaiting, "redo puts \"not waiting\" back")
    #expect(try store.setWaitingOverride(MailStoreWaiting.ref(thread), .waiting) == .waiting, "undo restored \"waiting\"")
    _ = try await port.undo(first)
    #expect(try store.setWaitingOverride(MailStoreWaiting.ref(thread), nil) == nil, "undo cleared the choice")
}

@Test(.timeLimit(.minutes(1))) func anUnknownThreadIsNotFound() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 5, now: now))
    let port = MailStoreWaiting(store: store)
    let unknown = ThreadKey(account: account, rowID: 987_654, gmailThreadID: GmailThreadID("absent"))
    await #expect(throws: MailPortError.notFound("thread")) { try await port.setChoice(.notWaiting, for: unknown) }
    await #expect(throws: MailPortError.self) { try await port.undo(UndoToken(payload: Data("x".utf8))) }
}
