import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMail

private let now = Date(timeIntervalSince1970: 1_791_000_000)

private func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>, where predicate: (T) -> Bool = { _ in true }) async throws -> T {
    for try await value in stream where predicate(value) { return value }
    throw CancellationError()
}

@Test(.timeLimit(.minutes(1))) func windowMapsStoreRowsInInboxOrder() async throws {
    let corpus = FakeCorpus.make(threadCount: 30, now: now)
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: corpus)
    let adapter = MailStoreAdapter(store: store)
    let window = try await first(adapter.threadWindow(.system(.inbox), account: account, limit: 10))
    #expect(window.rows.count == 10)
    #expect(window.hasMore)
    #expect(window.totalCount == 30)
    #expect(window.rows.map(\.id.gmailThreadID) == corpus.threads.prefix(10).map(\.row.id.gmailThreadID))
    #expect(window.rows.map(\.subject) == corpus.threads.prefix(10).map(\.row.subject))
    #expect(window.rows.map(\.isUnread) == corpus.threads.prefix(10).map(\.row.isUnread))
    #expect(window.rows.map(\.messageCount) == corpus.threads.prefix(10).map(\.row.messageCount))
    #expect(window.rows.allSatisfy { $0.id.account == account })
}

@Test(.timeLimit(.minutes(1))) func windowFollowsNewMail() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: now)
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: corpus)
    var iterator = MailStoreAdapter(store: store).threadWindow(.system(.inbox), account: account, limit: 50).makeAsyncIterator()
    #expect(try await iterator.next()?.totalCount == 5)
    let fresh = MessageUpsert(
        gmailMessageID: GmailMessageID("new-1"), gmailThreadID: GmailThreadID("new-t"), historyID: HistoryID(10_000),
        internalDate: now.addingTimeInterval(3_600), labelIDs: [GmailLabelID("INBOX"), GmailLabelID("UNREAD")],
        snippet: "Fresh", sizeEstimate: 10,
        headers: MessageHeaderFields(subject: "Brand new", from: EmailAddress(name: "Dana Ruiz", email: "dana@example.com"),
                                     to: [EmailAddress(email: FakeCorpus.me.email)], cc: [], bcc: [], replyTo: [], references: []))
    _ = try store.upsertMessages([fresh], account: account, generation: 1)
    var next = try await iterator.next()
    while next?.totalCount == 5 { next = try await iterator.next() }
    #expect(next?.totalCount == 6)
    #expect(next?.rows.first?.subject == "Brand new")
    #expect(next?.rows.first?.isUnread == true)
}

@Test(.timeLimit(.minutes(1))) func detailAndBodiesMap() async throws {
    let corpus = FakeCorpus.make(threadCount: 20, now: now)
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: corpus)
    let adapter = MailStoreAdapter(store: store)
    let window = try await first(adapter.threadWindow(.system(.inbox), account: account, limit: 20))
    let source = try #require(corpus.threads.first { $0.detail.messages.count >= 2 })
    let key = try #require(window.rows.first { $0.id.gmailThreadID == source.row.id.gmailThreadID }?.id)
    let detail = try #require(try await first(adapter.threadDetail(key)))
    #expect(detail.subject == source.detail.subject)
    #expect(detail.messages.map(\.id.gmailMessageID) == source.detail.messages.map(\.id.gmailMessageID))
    #expect(detail.messages.map(\.from) == source.detail.messages.map(\.from))
    let message = try #require(detail.messages.last)
    let body = try await first(adapter.body(message.id))
    let expected = try #require(source.bodies.first { $0.key.gmailMessageID == message.id.gmailMessageID }?.value)
    #expect(body == .available(expected))
}

@Test(.timeLimit(.minutes(1))) func missingBodyIsFetchingAndAsksSyncOnce() async throws {
    let corpus = FakeCorpus.make(threadCount: 3, now: now)
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: corpus, withBodies: false)
    let asked = AskedLog()
    let adapter = MailStoreAdapter(store: store, ensureBody: { await asked.add($0) })
    let message = try await lastMessage(adapter, account: account)
    var iterator = adapter.body(message.id).makeAsyncIterator()
    #expect(try await iterator.next() == .fetching)
    #expect(await asked.keys == [message.id])
    let source = try #require(corpus.threads.flatMap { $0.bodies }.first { $0.key.gmailMessageID == message.id.gmailMessageID })
    try store.storeBodies([(message.id.gmailMessageID, MessageBodyUpsert(html: source.value.html, text: source.value.text,
                                                                        hasCalendarInvite: false, decodeWarnings: [],
                                                                        searchText: ""), [])], account: account)
    #expect(try await iterator.next() == .available(source.value))
    #expect(await asked.keys.count == 1)
}

@Test(.timeLimit(.minutes(1))) func failedFetchIsReported() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now), withBodies: false)
    struct Offline: Error {}
    let adapter = MailStoreAdapter(store: store, ensureBody: { _ in throw Offline() })
    let message = try await lastMessage(adapter, account: account)
    var iterator = adapter.body(message.id).makeAsyncIterator()
    #expect(try await iterator.next() == .fetching)
    guard case .failed = try await iterator.next() else { Issue.record("expected failed"); return }
    try store.markBodyFailed(message.id.gmailMessageID, account: account, reason: "test")
    var again = MailStoreAdapter(store: store).body(message.id).makeAsyncIterator()
    guard case .failed = try await again.next() else { Issue.record("expected failed"); return }
}

private func lastMessage(_ adapter: MailStoreAdapter, account: AccountID) async throws -> MessageSummary {
    let window = try await first(adapter.threadWindow(.system(.inbox), account: account, limit: 3))
    let detail = try #require(try await first(adapter.threadDetail(window.rows[0].id)))
    return try #require(detail.messages.last)
}

@Test(.timeLimit(.minutes(1))) func locationsMapToStoreViews() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    let adapter = MailStoreAdapter(store: store)
    await #expect(throws: MailPortError.self) {
        _ = try await first(adapter.threadWindow(.reviewQueue(nil), account: account, limit: 10))
    }
    #expect(MailStoreAdapter.mailboxView(.reviewQueue(nil), account: account) == nil)
    #expect(MailStoreAdapter.mailboxView(.search("from:dana"), account: account) == nil)
    #expect(MailStoreAdapter.mailboxView(.system(.drafts), account: account) == .system(account, .drafts))
    #expect(MailStoreAdapter.mailboxView(.system(.trash), account: account) == .system(account, .trash))
    #expect(MailStoreAdapter.mailboxView(.system(.spam), account: account) == .system(account, .spam))
    #expect(MailStoreAdapter.mailboxView(.system(.starred), account: account) == .system(account, .starred))
    #expect(MailStoreAdapter.mailboxView(.splitOther, account: account) == .splitOther(account))
}

@Test(.timeLimit(.minutes(1))) func accountsMap() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    let accounts = try await first(MailStoreAdapter(store: store).accounts())
    #expect(accounts.map(\.id) == [account])
    #expect(accounts.first?.email == FakeCorpus.me.email)
    #expect(accounts.first?.health == .active)
}

@Test(.timeLimit(.minutes(1))) func sendAsIdentitiesMap() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    try store.updateSendAs(account: account, identities: [
        SendAsIdentity(email: FakeCorpus.me.email, name: "Robin", isDefault: false, isPrimary: true),
        SendAsIdentity(email: "robin@team.example", name: "Robin (Team)", isDefault: true, isPrimary: false,
                       signatureHTML: "<p>Team</p>", replyTo: "team@team.example"),
    ])
    let accounts = try await first(MailStoreAdapter(store: store).accounts()) { $0.first?.sendAs.count == 2 }
    let mapped = try #require(accounts.first)
    #expect(mapped.sendAs.map(\.email) == [FakeCorpus.me.email, "robin@team.example"])
    #expect(mapped.sendAs[1].isDefault && !mapped.sendAs[1].isPrimary && mapped.sendAs[1].signatureHTML == "<p>Team</p>")
    #expect(mapped.isMe("ROBIN@team.example") && mapped.isMe(FakeCorpus.me.email) && !mapped.isMe("dana@example.com"))
}

@Test(.timeLimit(.minutes(1))) func sendAsVerificationStatusAndSignaturesMap() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    try store.updateSendAs(account: account, identities: [
        SendAsIdentity(email: FakeCorpus.me.email, isDefault: true, isPrimary: true, signatureHTML: "<div>Robin</div>"),
        SendAsIdentity(email: "robin@relay.example", isDefault: false, isPrimary: false, verificationStatus: "pending"),
        SendAsIdentity(email: "robin@team.example", isDefault: false, isPrimary: false, verificationStatus: "accepted"),
    ])
    let accounts = try await first(MailStoreAdapter(store: store).accounts()) { $0.first?.sendAs.count == 3 }
    let sendAs = try #require(accounts.first).sendAs
    #expect(sendAs.map(\.needsVerification) == [false, true, false])
    #expect(sendAs.map(\.signatureHTML) == ["<div>Robin</div>", nil, nil])
    #expect(!MailStoreAdapter.needsVerification(nil) && !MailStoreAdapter.needsVerification("Accepted"))
}

@Test(.timeLimit(.minutes(1))) func draftsSnippetsAndContactsMapForTheComposer() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 3, now: now))
    let content = DraftContent(from: EmailAddress(email: FakeCorpus.me.email),
                               to: [EmailAddress(name: "Dana Ruiz", email: "dana@example.org")], cc: [], bcc: [],
                               subject: "Synthetic", bodyHTML: "<p>Synthetic</p>", bodyText: "Synthetic",
                               attachments: [DraftAttachment(localPath: "Drafts/x/notes.txt", filename: "notes.txt",
                                                             mimeType: "text/plain", size: 9, isInline: false)])
    let id = try store.createDraft(account: account, mode: .new, replyTo: nil, content: content, origin: .user,
                                   reviewState: .none, agentNote: nil, extraHeaders: [:])
    let version = try store.updateDraft(id, content: content, expectedVersion: nil)
    let adapter = MailStoreAdapter(store: store)
    let summary = try #require(try await first(adapter.draft(id)) { $0?.version == version })
    #expect(summary.account == account && summary.mode == .new && summary.status == .editing && summary.source == .user)
    #expect(summary.review == .none && summary.thread == nil && summary.version == version)
    #expect(summary.fields == MailStoreAdapter.fields(content) && MailStoreAdapter.content(summary.fields) == content)
    #expect(try await first(adapter.drafts(account, review: false)).map(\.id) == [id])
    #expect(try await first(adapter.reviewQueue(account)).isEmpty)
    _ = try store.discardDraft(id)
    #expect(try await first(adapter.draft(id)) == nil, "a discarded row reads as gone")
    #expect(try await first(adapter.drafts(account, review: false)).isEmpty)

    try store.upsertSnippet(SnippetItem(id: "s1", name: "Thanks", shortcut: "ty", bodyHTML: "<p>Thanks, {{first_name}}</p>",
                                        variables: [SnippetVariable(name: "first_name")], useCount: 2))
    let snippets = try await first(adapter.snippets(account))
    #expect(snippets.map(\.id) == ["s1"] && snippets.first?.shortcut == "ty" && snippets.first?.variables.map(\.name) == ["first_name"])
    _ = try await adapter.contactSuggestions(account, prefix: "a", limit: 6)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func compositionRootChoosesTheDataSource() {
    #expect(CompositionRoot.dataMode(arguments: ["-UseFakeData"], environment: [:]) == .fake)
    #expect(CompositionRoot.dataMode(arguments: ["-UseFixtureStore"], environment: [:]) == .fixtureStore)
    #expect(CompositionRoot.dataMode(arguments: [], environment: ["XCTestConfigurationFilePath": "x"]) == .fake)
    #expect(CompositionRoot.dataMode(arguments: ["-UseFakeGmail"], environment: [:]) == .fakeGmail)
    #expect(CompositionRoot.dataMode(arguments: ["-UseFakeGmail"], environment: ["XCTestConfigurationFilePath": "x"]) == .fakeGmail)
    #expect(CompositionRoot.dataMode(arguments: [], environment: [:]) == .live)
    guard case .mail(let environment) = CompositionRoot.makeApp(arguments: ["-UseFixtureStore"], environment: [:]).screen else {
        Issue.record("expected the mail window")
        return
    }
    #expect(environment.isFake)
    #expect(environment.status.safeMode == .normal)
}

@Test(.timeLimit(.minutes(1))) func adapterPassesSafeModeAndConnectivity() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: .make(threadCount: 1, now: now))
    let adapter = MailStoreAdapter(store: store, safeMode: .readOnly, connectivity: {
        AsyncStream { $0.yield([account: .needsReauth]); $0.finish() }
    })
    #expect(adapter.safeMode() == .readOnly)
    var states: [[AccountID: ConnectivityState]] = []
    for await state in adapter.connectivity() { states.append(state) }
    #expect(states == [[account: .needsReauth]])
    #expect(MailStoreAdapter(store: store).safeMode() == .normal)
    var none = 0
    for await _ in MailStoreAdapter(store: store).connectivity() { none += 1 }
    #expect(none == 0)
}

private actor AskedLog {
    var keys: [MessageKey] = []
    func add(_ key: MessageKey) { keys.append(key) }
}
