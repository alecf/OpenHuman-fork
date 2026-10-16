import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func threadWindowEmitsCurrentValueThenChanges() async throws {
    let store = FakeMailStore(corpus: .make(threadCount: 30, now: fixedNow))
    var iterator = store.threadWindow(.system(.inbox), account: work, limit: 10).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    #expect(first.rows.count == 10)
    #expect(first.hasMore)
    #expect(first.totalCount == 30)
    store.removeThreads([first.rows[0].id])
    let second = try #require(try await iterator.next())
    #expect(second.totalCount == 29)
    #expect(second.rows.first?.id == first.rows[1].id)
}

@Test func storeRowsMatchTheCorpusRows() async throws {
    let corpus = FakeCorpus.make(threadCount: 40, now: fixedNow)
    let rows = try await window(FakeMailStore(corpus: corpus), .system(.inbox)).rows
    #expect(rows == corpus.threads.map(\.row))
}

@Test func emptyLocationsAndUnknownAccountsAreEmpty() async throws {
    let store = FakeMailStore(corpus: .make(threadCount: 5, now: fixedNow))
    #expect(try await window(store, .system(.trash)).rows.isEmpty)
    #expect(try await window(store, .system(.inbox), account: AccountID(99)).totalCount == 0)
}

@Test func bodiesResolveWithOptionalDelay() async throws {
    let corpus = FakeCorpus.make(threadCount: 3, now: fixedNow)
    let key = corpus.threads[0].detail.messages[0].id
    let delayed = FakeMailStore(corpus: corpus, bodyDelay: .milliseconds(10))
    var iterator = delayed.body(key).makeAsyncIterator()
    #expect(try await iterator.next() == .fetching)
    guard case .available = try await iterator.next() else { Issue.record("expected body"); return }
    let missing = MessageKey(account: work, rowID: 999_999, gmailMessageID: GmailMessageID("nope"))
    var miss = FakeMailStore(corpus: corpus).body(missing).makeAsyncIterator()
    #expect(try await miss.next() == .failed("Message not found"))
}

@Test func locationsFollowTheLabelState() async throws {
    let store = makeStore()
    let inbox = try await keys(store, .system(.inbox))
    #expect(inbox.contains(special(0).row.id) && !inbox.contains(special(8).row.id) && !inbox.contains(special(17).row.id))
    #expect(try await keys(store, .system(.trash)).contains(special(17).row.id))
    #expect(try await keys(store, .system(.spam)).contains(special(18).row.id))
    #expect(try await keys(store, .system(.sent)).contains(special(19).row.id))
    let allMail = try await keys(store, .system(.allMail))
    #expect(allMail.contains(special(20).row.id) && !allMail.contains(special(17).row.id) && !allMail.contains(special(18).row.id))
    #expect(try await keys(store, .system(.starred)).contains(special(1).row.id))
    let snoozed = try await window(store, .system(.snoozed)).rows
    #expect(snoozed.map(\.id) == [special(10).row.id, special(8).row.id, special(9).row.id], "unknown wake time first, then soonest")
    #expect(snoozed[0].snoozedUntil == nil && snoozed[1].snoozedUntil != nil)
    let reminders = try await window(store, .system(.reminders)).rows
    #expect(reminders.map(\.id) == [special(11).row.id, special(12).row.id])
    #expect(reminders.allSatisfy { $0.reminderAt == $0.sortAt })
    let scheduled = try await window(store, .system(.scheduled)).rows
    #expect(scheduled.map(\.id) == [special(16).row.id] && scheduled[0].scheduledSendAt != nil)
    #expect(try await keys(store, .system(.drafts)).contains(special(0).row.id))
    let atlas = try #require(special(21).labels.values.flatMap { $0 }.first { $0.rawValue.hasPrefix("Label_") })
    #expect(try await keys(store, .label(atlas)) == [special(21).row.id])
    #expect(try await keys(store, .reviewQueue(nil)).count == 3)
}

@Test func splitsPartitionTheInbox() async throws {
    let store = makeStore()
    let splits = try await first(store.splits(work))
    #expect(splits.map(\.name) == ["Important", "Newsletters"])
    let inbox = Set(try await keys(store, .system(.inbox)))
    let important = try await window(store, .split(splits[0].id)).rows
    let newsletters = Set(try await keys(store, .split(splits[1].id)))
    let other = Set(try await keys(store, .splitOther))
    #expect(important.allSatisfy { $0.isImportant })
    #expect(newsletters.contains(special(5).row.id))
    #expect(Set(important.map(\.id)).union(newsletters).union(other) == inbox)
    #expect(Set(important.map(\.id)).isDisjoint(with: newsletters) && newsletters.isDisjoint(with: other))
    let counts = try await first(store.counts(work))
    let unreadInbox = try await window(store, .system(.inbox)).rows.filter { $0.isUnread }.count
    #expect(counts.inboxUnread == unreadInbox)
    #expect(counts.splitUnread[splits[0].id] == important.filter { $0.isUnread }.count)
    let inboxRows = try await window(store, .system(.inbox)).rows
    #expect(counts.importantUnread == inboxRows.filter { $0.isUnread && $0.isImportant }.count)
    #expect(counts.pendingReviewCount == 4)
    #expect(splits[0].totalThreads == important.count)
}

@Test func labelsCarryCounts() async throws {
    let store = makeStore()
    let labels = try await first(store.labels(work))
    let inbox = try #require(labels.first { $0.labelID == GmailLabelID("INBOX") })
    #expect(inbox.totalThreads == (try await window(store, .system(.inbox))).totalCount)
    #expect(labels.first { $0.labelID == GmailLabelID("oh:snoozed") }?.totalThreads == 3)
    #expect(labels.map(\.position) == labels.map(\.position).sorted())
    let counts = try await first(store.counts(work))
    #expect(counts.byLabel[inbox.id] == LabelTally(total: inbox.totalThreads, unread: inbox.unreadThreads))
}

@Test func threadPagesWalkTheWholeLocation() async throws {
    let store = makeStore()
    let total = try await window(store, .system(.allMail)).totalCount
    var seen: [ThreadKey] = []
    var cursor: PageCursor?
    repeat {
        let page = try await store.threadPage(.system(.allMail), account: work, after: cursor, limit: 25)
        seen += page.rows.map(\.id)
        cursor = page.next
    } while cursor != nil
    #expect(seen.count == total && Set(seen).count == total)
    #expect(seen == (try await keys(store, .system(.allMail))))
}

@Test func searchUnderstandsTheCommonOperators() async throws {
    let store = makeStore()
    let unread = try await first(store.search("is:unread", accounts: [work], limit: 500))
    #expect(!unread.hits.isEmpty && unread.hits.allSatisfy { $0.row.isUnread })
    let fromDana = try await first(store.search("from:dana@example.com", accounts: nil, limit: 500))
    #expect(!fromDana.hits.isEmpty)
    let label = try await first(store.search("label:Clients", accounts: [work], limit: 500))
    #expect(label.hits.map(\.row.id).contains(special(20).row.id))
    let invite = try await first(store.search("has:invite", accounts: [work], limit: 500))
    #expect(invite.hits.map(\.row.id) == [special(1).row.id])
    let trashOnly = try await first(store.search("in:trash", accounts: [work], limit: 500))
    #expect(trashOnly.hits.map(\.row.id).contains(special(17).row.id))
    let free = try await first(store.search("\"\(special(4).row.subject)\"", accounts: [work], limit: 5))
    #expect(free.hits.first?.row.id == special(4).row.id)
    #expect(try await window(store, .search("is:starred")).rows.allSatisfy { $0.isStarred })
    await #expect(throws: MailPortError.self) { _ = try await first(store.search("bogus:thing", accounts: nil, limit: 5)) }
}

@Test func conversationDetailCarriesDraftsSnoozeAndReminder() async throws {
    let store = makeStore()
    let withDraft = try #require(try await first(store.threadDetail(special(0).row.id)))
    #expect(withDraft.drafts.count == 1 && withDraft.messages.count == special(0).row.messageCount)
    let twoStamps = try #require(try await first(store.threadDetail(special(9).row.id)))
    guard case .until(_, let count) = twoStamps.snooze else { Issue.record("expected a wake time"); return }
    #expect(count == 2)
    #expect(try await first(store.threadDetail(special(10).row.id))?.snooze == .wakeTimeUnknown)
    #expect(try await first(store.threadDetail(special(11).row.id))?.reminder?.kind == .always)
    let trashed = try #require(try await first(store.threadDetail(special(17).row.id)))
    #expect(!trashed.messages.isEmpty, "a thread whose messages are all in Trash still shows them")
}

@Test func attachmentsAndUnsubscribeInfo() async throws {
    let store = makeStore()
    let invite = try #require(special(1).detail.messages.last)
    let ics = try #require(invite.attachments.first { $0.mimeType == "text/calendar" })
    let file = try await store.attachmentData(invite.id, attachment: ics)
    #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("BEGIN:VCALENDAR"))
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    let oneClick = try #require(special(5).detail.messages.last?.id)
    #expect(try await store.unsubscribeInfo(oneClick) == .oneClick(host: "news.example"))
    let mailto = try #require(special(6).detail.messages.last?.id)
    guard case .mailto = try await store.unsubscribeInfo(mailto) else { Issue.record("expected mailto"); return }
    #expect(try await store.unsubscribeInfo(special(0).detail.messages[0].id) == nil)
    try await store.unsubscribe(oneClick)
    #expect(store.unsubscribeRequests == [oneClick])
    await #expect(throws: MailPortError.self) { try await store.unsubscribe(mailto) }
}

@Test func contactSuggestionsRankByPrefix() async throws {
    let store = makeStore()
    let suggestions = try await store.contactSuggestions(work, prefix: "da", limit: 5)
    #expect(suggestions.first?.email == "dana@example.com")
    #expect(suggestions.allSatisfy { $0.email != FakeCorpus.me.email })
}

@Test func diagnosticsSnapshotHasNoMailContent() async throws {
    let store = makeStore()
    _ = try await store.apply(.markDone([special(0).row.id]))
    store.failRemote(code: "server_503")
    let snapshot = try await store.diagnosticsSnapshot()
    #expect(snapshot.accounts.map(\.index) == [1, 2])
    #expect(snapshot.accounts[0].failedOperations == 1)
    #expect(snapshot.recentErrors.first?.code == "server_503")
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    let corpus = FakeCorpus.rich(threadCount: 120, now: fixedNow)
    var markers = corpus.accounts.map(\.email) + ["Clients", "Atlas", "@"]
    markers += corpus.mailboxes.flatMap(\.threads).prefix(30).map(\.row.subject)
    for marker in markers { #expect(!json.contains(marker), "diagnostics contain \(marker)") }
}

@Test func everyReadMemberIsImplemented() async throws {
    let store = makeStore()
    let thread = special(2)
    let message = try #require(thread.detail.messages.last)
    _ = try await first(store.accounts())
    _ = try await first(store.labels(work))
    _ = try await first(store.splits(work))
    _ = try await first(store.counts(work))
    _ = try await store.threadPage(.system(.inbox), account: work, after: nil, limit: 5)
    _ = try await first(store.threadDetail(thread.row.id))
    _ = try await first(store.body(message.id))
    let file = try await store.attachmentData(message.id, attachment: try #require(message.attachments.first))
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    _ = try await first(store.search("is:unread", accounts: nil, limit: 5))
    _ = try await first(store.drafts(nil, review: false))
    _ = try await first(store.draft(DraftKey("missing")))
    _ = try await first(store.reviewQueue(nil))
    _ = try await store.contactSuggestions(work, prefix: "", limit: 3)
    _ = try await first(store.snippets(nil))
    _ = try await first(store.reminders(nil))
    _ = try await first(store.failedOperations(nil))
    _ = try await store.unsubscribeInfo(message.id)
    _ = try await store.diagnosticsSnapshot()
    _ = await first(store.oauthClientStatus())
}
