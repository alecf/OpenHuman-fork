import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SenderSweepScopeTests {
    @Test func trashCleanupLeavesOutConversationsTheUserIsPartOf() async throws {
        let corpus = FakeCorpus.rich(threadCount: 200, now: fixedNow)
        let f = ActionFixture(corpus: corpus)
        let handler = try #require(f.registry.threadActions)
        let mine = corpus.account.myAddresses
        var bySender: [String: Set<ThreadKey>] = [:]
        for thread in corpus.threads {
            for message in thread.detail.messages {
                guard let email = message.from?.email.lowercased(), !mine.contains(email) else { continue }
                bySender[email, default: []].insert(thread.row.id)
            }
        }
        let senders = bySender.keys.sorted { (bySender[$0]?.count ?? 0, $1) > (bySender[$1]?.count ?? 0, $0) }
        var replies = 0
        var chosen: (sweep: SenderSweep, targets: [ThreadKey])?
        for sender in senders {
            let sweep = SenderSweep(address: sender, account: corpus.account.id, thread: nil)
            let targets = await handler.sweepTargets(sweep, scope: .all)
            let replied = corpus.threads.filter { thread in
                thread.detail.messages.contains { $0.from?.email.lowercased() == sender }
                    && thread.detail.messages.contains { mine.contains($0.from?.email.lowercased() ?? "") }
            }.map(\.row.id)
            replies += replied.count
            for key in replied { #expect(!targets.contains(key), "the user wrote in it") }
            if chosen == nil, targets.count >= 4 { chosen = (sweep, targets) }
        }
        #expect(replies > 0, "the corpus has conversations the user replied in")
        let (sweep, before) = try #require(chosen, "a sender with four conversations to sweep")
        let label = try #require(corpus.mailboxes[0].labels.first { $0.kind == .user && !$0.isHidden })
        _ = try await f.store.apply(.star([before[0]]))
        _ = try await f.store.apply(.modifyLabels([before[1]], add: [label.labelID], remove: []))
        _ = try await f.store.apply(.setReminder(before[2], dueAt: fixedNow.addingTimeInterval(86_400), kind: .always))
        let after = await handler.sweepTargets(sweep, scope: .all)
        #expect(!after.contains(before[0]), "starred")
        #expect(!after.contains(before[1]), "labelled")
        #expect(!after.contains(before[2]), "reminder set")
        #expect(after.contains(before[3]), "the sender's own conversation is still swept")
    }

    @Test func onlyConversationsTheSenderAloneWroteAndNobodyMarkedAreTrashable() {
        let sender = "news@vendor.example"
        let sweep = SenderSweep(address: sender, account: AccountID(1), thread: nil)
        func row(_ id: Int64, starred: Bool = false, labels: [Int64] = [], snoozed: Date? = nil, reminder: Date? = nil,
                 drafts: Int = 0, people: [Participant]? = nil) -> ThreadRow {
            ThreadRow(id: ThreadKey(account: AccountID(1), rowID: id, gmailThreadID: GmailThreadID("t\(id)")),
                      subject: "Weekly \(id)", snippet: "", participantsDisplay: "Vendor",
                      participants: people ?? [Participant(name: "Vendor", email: "News@Vendor.example", isMe: false, hasUnread: false)],
                      messageCount: 1, unreadCount: 0, draftCount: drafts, attachmentCount: 0, isUnread: false,
                      isStarred: starred, isImportant: false, userLabelIDs: labels, lastMessageAt: fixedNow, sortAt: fixedNow,
                      snoozedUntil: snoozed, reminderAt: reminder)
        }
        let vendor = Participant(name: "Vendor", email: sender, isMe: false, hasUnread: false)
        let rows = [
            row(1), row(2), row(3),
            row(4, people: [vendor, Participant(name: "Me", email: "me@example.test", isMe: true, hasUnread: false)]),
            row(5, starred: true),
            row(6, labels: [42]),
            row(7, snoozed: fixedNow),
            row(8, reminder: fixedNow),
            row(9, drafts: 1),
            row(10, people: [vendor, Participant(name: "Sam", email: "sam@example.test", isMe: false, hasUnread: false)]),
        ]
        #expect(sweep.trashable(rows).map(\.rowID) == [1, 2, 3])
    }

    @Test func theOfferWordingCountsWhatTrashLeavesOut() {
        let text = ThreadActionHandler.cleanupMessage(count: 41, capped: false, hasAddress: true, leftOut: 3)
        #expect(text.contains("41 conversations"))
        #expect(text.contains("3"))
        #expect(!ThreadActionHandler.cleanupMessage(count: 41, capped: false, hasAddress: true).contains("leaves out"))
    }
}
