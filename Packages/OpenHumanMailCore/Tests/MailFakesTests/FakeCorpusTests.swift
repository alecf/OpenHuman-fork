import Foundation
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func corpusIsDeterministic() {
    let a = FakeCorpus.make(threadCount: 50, now: fixedNow)
    let b = FakeCorpus.make(threadCount: 50, now: fixedNow)
    #expect(a.threads.map(\.row) == b.threads.map(\.row))
    #expect(a.threads.count == 50)
    #expect(FakeCorpus.rich(threadCount: 80, now: fixedNow).mailboxes.map { $0.threads.map(\.row) }
        == FakeCorpus.rich(threadCount: 80, now: fixedNow).mailboxes.map { $0.threads.map(\.row) })
}

@Test func inboxCorpusIsNewestFirstAndAllInTheInbox() {
    let corpus = FakeCorpus.make(threadCount: 200, now: fixedNow)
    let dates = corpus.threads.map(\.row.sortAt)
    #expect(dates == dates.sorted(by: >))
    let kinds = Set(corpus.threads.flatMap { $0.bodyKinds.values })
    #expect(kinds == [.plainReply, .simpleHTML, .newsletter, .gmailReply, .hostile, .plainShort])
    #expect(corpus.threads.contains { $0.row.isUnread })
    #expect(corpus.threads.allSatisfy { $0.detail.messages.count == $0.row.messageCount })
    #expect(corpus.threads.allSatisfy { thread in thread.labels.values.contains { $0.contains(GmailLabelID("INBOX")) } })
    for thread in corpus.threads {
        let dates = thread.detail.messages.map(\.date)
        #expect(dates == dates.sorted(), "messages ascend inside a thread")
        #expect(dates.last == thread.row.lastMessageAt)
        #expect(thread.row.isUnread == thread.detail.messages.contains { $0.isUnread })
    }
}

@Test func participantsDisplayFollowsTheStoreRule() {
    func view(_ name: String, _ email: String, fromMe: Bool = false, to: [EmailAddress] = [], unread: Bool = false)
        -> FakeAggregator.MessageView {
        let summary = MessageSummary(id: MessageKey(account: work, rowID: 1, gmailMessageID: GmailMessageID("m")),
                                     from: EmailAddress(name: name, email: email), to: to, cc: [], bcc: [], date: fixedNow,
                                     snippet: "", isUnread: unread, attachments: [])
        return .init(summary: summary, labels: unread ? [GmailLabelID("UNREAD")] : [], isFromMe: fromMe)
    }
    let me: Set<String> = ["robin@example.com"]
    let robin = EmailAddress(name: "Robin Example", email: "robin@example.com")
    #expect(FakeAggregator.participants(scope: [view("Dana Ruiz", "dana@example.com")], me: me).0 == "Dana Ruiz")
    #expect(FakeAggregator.participants(scope: [view("Dana Ruiz", "dana@example.com", to: [robin])], me: me).0 == "Dana Ruiz")
    #expect(FakeAggregator.participants(scope: [view("Robin Example", "robin@example.com", fromMe: true, to: [EmailAddress(name: "Sam Lee", email: "sam@example.org")])], me: me).0 == "To: Sam Lee")
    #expect(FakeAggregator.participants(scope: [view("Robin Example", "robin@example.com", fromMe: true)], me: me).0 == "me")
    let three = [view("Dana Ruiz", "dana@example.com", unread: true), view("Robin Example", "robin@example.com", fromMe: true),
                 view("Sam Lee", "sam@example.org")]
    let (display, people) = FakeAggregator.participants(scope: three, me: me)
    #expect(display == "Sam, Dana (3)")
    #expect(people.map(\.isMe) == [false, false, true])
    #expect(people[1].hasUnread == true)
    let many = ["Ann A", "Bo B", "Cy C", "Di D"].enumerated().map { view($1, "p\($0)@example.org") }
    #expect(FakeAggregator.participants(scope: many, me: me).0 == "Di, Cy, Bo +1 (4)")
}

@Test func richCorpusHasTwoAccountsAndEveryState() throws {
    let corpus = FakeCorpus.rich(threadCount: 200, now: fixedNow)
    #expect(corpus.accounts.map(\.id) == [work, personal])
    #expect(corpus.mailboxes.map(\.threads.count) == [140, 60])
    #expect(corpus.accounts.map(\.alias) == ["Work", "Personal"])
    #expect(corpus.account.sendAs.count == 2 && corpus.account.sendAs.contains { $0.signatureHTML != nil })
    let all = corpus.mailboxes.flatMap(\.threads)
    let labels = all.flatMap { $0.labels.values.flatMap { $0 } }.map(\.rawValue)
    for system in ["INBOX", "UNREAD", "STARRED", "IMPORTANT", "SENT", "TRASH", "SPAM", "CATEGORY_PROMOTIONS",
                   "CATEGORY_UPDATES", "CATEGORY_SOCIAL"] {
        #expect(labels.contains(system), "missing \(system)")
    }
    #expect(all.contains { $0.row.userLabelIDs.count >= 2 }, "a thread with two user labels")
    #expect(all.contains { $0.detail.messages.count >= 12 }, "a long conversation")
    let attachments = all.flatMap { $0.detail.messages.flatMap(\.attachments) }
    #expect(Set(attachments.map(\.mimeType)).isSuperset(of: ["application/pdf", "image/png", "text/calendar"]))
    #expect(attachments.contains { $0.isInline && $0.contentID == FakeBodies.inlineImageContentID })
    #expect(all.contains { $0.detail.messages.contains { $0.hasCalendarInvite } })
    #expect(Set(all.flatMap { $0.bodyKinds.values }) == Set(FakeBodyKind.allCases))
    let unsubscribes = all.flatMap(\.unsubscribe.values)
    #expect(unsubscribes.contains { if case .oneClick = $0 { true } else { false } })
    #expect(unsubscribes.contains { if case .mailto = $0 { true } else { false } })
    #expect(unsubscribes.contains { if case .link = $0 { true } else { false } })

    let box = corpus.mailboxes[0]
    #expect(box.labels.contains { $0.name == "Projects/Atlas" && $0.displayName == "Atlas" && $0.colorBackground != nil })
    #expect(box.labels.contains { $0.name.hasPrefix("OpenHuman/Snoozed/") && $0.isHidden })
    #expect(box.splits.map(\.name) == ["Important", "Newsletters"])
    #expect(corpus.mailboxes[1].splits.map(\.name) == ["Important"])
    #expect(box.reminders.map(\.kind) == [.always, .ifNoReply])
    let drafts = box.drafts
    #expect(drafts.filter { $0.source == .agent && $0.review == .pending }.count == 3)
    #expect(drafts.contains { $0.source == .cli && $0.review == .pending && $0.thread == nil })
    #expect(drafts.contains { $0.source == .agent && $0.review == .approved })
    #expect(drafts.filter { $0.status == .scheduled }.count == 2)
    #expect(drafts.contains { $0.status == .failed && $0.lastError == "scheduled time unreadable" })
    #expect(drafts.contains { $0.mode == .new && $0.isDirty })
    #expect(corpus.snippets.map(\.shortcut) == ["thx", "intro", "fu"])
    let threadRows = all.map(\.row.id.rowID)
    #expect(Set(threadRows).count == threadRows.count)
    let messageRows = all.flatMap { $0.allMessages.map(\.id.rowID) }
    #expect(Set(messageRows).count == messageRows.count)
}

@Test func richCorpusRendersSafely() {
    let corpus = FakeCorpus.rich(threadCount: 60, now: fixedNow)
    var seen = Set<FakeBodyKind>()
    for thread in corpus.mailboxes.flatMap(\.threads) {
        for (key, content) in thread.bodies {
            guard let kind = thread.bodyKinds[key] else { continue }
            seen.insert(kind)
            switch MessageRenderer().render(content) {
            case .html(let rendered):
                let lower = rendered.html.lowercased()
                for needle in ["<script", "javascript:", "onerror", "onload", "<iframe", "<form"] {
                    #expect(!lower.contains(needle), "\(kind) kept \(needle)")
                }
                if kind == .cidImage { #expect(rendered.html.contains("ohcid:")) }
                if kind == .newsletter { #expect(rendered.hasRemoteContent && rendered.trackerCount == 1) }
            case .plain:
                #expect(content.html == nil, "\(kind) has HTML but rendered as plain text")
            case .empty:
                Issue.record("empty body for \(kind)")
            }
        }
    }
    #expect(seen == Set(FakeBodyKind.allCases))
}

@Test func largeCorpusHasTheExpectedShapeAndIsDeterministic() {
    let a = FakeCorpus.rich(threadCount: 2_000, now: fixedNow)
    let b = FakeCorpus.rich(threadCount: 2_000, now: fixedNow)
    #expect(a.mailboxes.map(\.threads.count) == [1_400, 600])
    #expect(a.mailboxes.map { $0.threads.map(\.row) } == b.mailboxes.map { $0.threads.map(\.row) })
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct FakeCorpusTimingTests {
    @Test func largeCorpusGeneratesQuickly() {
        func threadCPUSeconds() -> Double {
            var spec = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
            return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
        }
        var corpus: FakeCorpus?
        let start = threadCPUSeconds()
        let wall = ContinuousClock().measure { corpus = FakeCorpus.rich(threadCount: 50_000, now: fixedNow) }
        let cpu = threadCPUSeconds() - start
        #expect(corpus?.mailboxes.map(\.threads.count) == [35_000, 15_000])
        #expect(cpu < 2, "took \(cpu) s of CPU (\(wall) wall)")
    }
}
