import Foundation
import MailModel
import OpenHumanCore
@testable import MailFakes

let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)
let work = AccountID(1)
let personal = AccountID(2)

func makeStore(threads: Int = 120, clock: FakeClock = FakeClock(fixedNow), ack: FakeMailStore.Options.RemoteAck = .manual,
               oauthClient: OAuthClientStatus = .configured(source: .file),
               liveConnectivity: Bool = false) -> FakeMailStore {
    FakeMailStore(corpus: .rich(threadCount: threads, now: fixedNow),
                  options: .init(remoteAck: ack, heldSends: .manual, liveConnectivity: liveConnectivity,
                                 oauthClient: oauthClient, now: { clock.now }))
}

func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>, where predicate: (T) -> Bool = { _ in true }) async throws -> T {
    for try await value in stream where predicate(value) { return value }
    throw CancellationError()
}

func first<T: Sendable>(_ stream: AsyncStream<T>, where predicate: (T) -> Bool = { _ in true }) async -> T? {
    for await value in stream where predicate(value) { return value }
    return nil
}

func window(_ store: FakeMailStore, _ location: MailLocation, account: AccountID = work, limit: Int = 500) async throws -> ThreadListWindow {
    try await first(store.threadWindow(location, account: account, limit: limit))
}

func keys(_ store: FakeMailStore, _ location: MailLocation, account: AccountID = work) async throws -> [ThreadKey] {
    try await window(store, location, account: account).rows.map(\.id)
}

func special(_ index: Int, account: Int = 0, threads: Int = 120) -> FakeCorpus.Thread {
    FakeCorpus.rich(threadCount: threads, now: fixedNow).mailboxes[account].threads[index]
}
