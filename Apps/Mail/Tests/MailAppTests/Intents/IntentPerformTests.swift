import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import Testing
@testable import OpenHumanMail

@MainActor
final class RecordingIntents: IntentPerforming {
    var calls: [String] = []
    var focusStates: [FocusFilterState?] = []
    var accountList = [IntentAccount(id: "1", title: "Work"), IntentAccount(id: "2", title: "Personal")]
    let thread = IntentThread(id: "oh.thread.1.t1", link: URL(string: "openhuman://thread/me@example.com/t1")!,
                              senderName: "Dana", date: Date(timeIntervalSince1970: 1_791_000_000), isImportant: true,
                              isUnread: true, accountName: "Work", subject: "")

    func countUnread(account: String?, kind: IntentUnreadKind) async throws -> Int {
        calls.append("countUnread \(account ?? "all") \(kind.rawValue)")
        return 7
    }

    func findConversations(_ query: String, account: String?, limit: Int, importantOnly: Bool) async throws -> [IntentThread] {
        calls.append("find \(query) \(account ?? "all") \(limit) \(importantOnly)")
        return [thread]
    }

    func openMailbox(_ mailbox: IntentMailbox, account: String?) async throws {
        calls.append("openMailbox \(mailbox.rawValue) \(account ?? "active")")
    }

    func openThread(_ id: String) async throws { calls.append("openThread \(id)") }

    func searchMail(_ query: String, account: String?) async throws {
        calls.append("search \(query) \(account ?? "active")")
    }

    func newMessage(account: String?, to: [String], subject: String?, body: String?) async throws {
        calls.append("newMessage \(account ?? "active") \(to.joined(separator: ",")) \(subject ?? "-") \(body ?? "-")")
    }

    func openReviewQueue(account: String?) async throws { calls.append("openReviewQueue \(account ?? "active")") }

    func markDone(_ ids: [String], confirm: IntentConfirmation) async throws -> String {
        calls.append("markDone \(ids.joined(separator: ","))")
        return "Marked 1 conversation done."
    }

    func snooze(_ ids: [String], until date: Date, confirm: IntentConfirmation) async throws -> String {
        calls.append("snooze \(ids.joined(separator: ",")) \(Int(date.timeIntervalSince1970))")
        return "Snoozed."
    }

    func remind(_ id: String, at date: Date, onlyIfNoReply: Bool, confirm: IntentConfirmation) async throws -> String {
        calls.append("remind \(id) \(Int(date.timeIntervalSince1970)) \(onlyIfNoReply)")
        return "Reminder set."
    }

    func accounts() async throws -> [IntentAccount] { accountList }
    func threads(for ids: [String]) async throws -> [IntentThread] { ids.contains(thread.id) ? [thread] : [] }
    func suggestedThreads() async throws -> [IntentThread] { [thread] }
    func threads(matching text: String) async throws -> [IntentThread] { [thread] }
    func applyFocusFilter(_ state: FocusFilterState?) async { focusStates.append(state) }
    func focusAccounts() async -> [IntentAccount] { accountList }
}

@MainActor
@Suite(.serialized) struct IntentPerformTests {
    private func withRecorder(_ body: (RecordingIntents) async throws -> Void) async rethrows {
        let recorder = RecordingIntents()
        IntentBridge.override = recorder
        defer { IntentBridge.override = nil }
        try await body(recorder)
    }

    @Test func readIntentsPassTheirParametersAndAnswer() async throws {
        try await withRecorder { recorder in
            var count = CountUnreadIntent()
            count.kind = .inbox
            count.account = AccountEntity(id: "2", title: "Personal")
            #expect(try await count.perform().value == 7)

            var find = FindConversationsIntent()
            find.query = "budget"
            find.limit = 3
            find.importantOnly = true
            let found = try await find.perform().value ?? []
            #expect(found.map(\.id) == ["oh.thread.1.t1"])
            #expect(found.first?.senderName == "Dana" && found.first?.subject == "")

            #expect(recorder.calls == ["countUnread 2 inbox", "find budget all 3 true"])
        }
    }

    @Test func navigationIntentsCallTheirEntry() async throws {
        try await withRecorder { recorder in
            var mailbox = OpenMailboxIntent()
            mailbox.mailbox = .snoozed
            _ = try await mailbox.perform()
            #expect(OpenMailboxIntent().mailbox == .inbox, "Open my inbox uses the default")

            var thread = OpenThreadIntent()
            thread.conversation = ThreadEntity(recorder.thread)
            _ = try await thread.perform()

            var search = SearchMailIntent()
            search.query = "from:dana"
            search.account = AccountEntity(id: "1", title: "Work")
            _ = try await search.perform()

            var compose = NewMessageIntent()
            compose.to = ["a@example.com", "b@example.com"]
            compose.subject = "Hi"
            _ = try await compose.perform()

            _ = try await OpenReviewQueueIntent().perform()

            #expect(recorder.calls == ["openMailbox snoozed active", "openThread oh.thread.1.t1", "search from:dana 1",
                                       "newMessage active a@example.com,b@example.com Hi -", "openReviewQueue active"])
        }
    }

    @Test func changeIntentsPassIdsAndReturnTheMessage() async throws {
        try await withRecorder { recorder in
            let entity = ThreadEntity(recorder.thread)
            var done = MarkDoneIntent()
            done.conversations = [entity]
            _ = try await done.perform()

            var snooze = SnoozeIntent()
            snooze.conversations = [entity]
            snooze.until = Date(timeIntervalSince1970: 1_791_086_400)
            _ = try await snooze.perform()

            var remind = RemindMeIntent()
            remind.conversation = entity
            remind.at = Date(timeIntervalSince1970: 1_791_086_400)
            remind.onlyIfNoReply = true
            _ = try await remind.perform()

            #expect(recorder.calls == ["markDone oh.thread.1.t1", "snooze oh.thread.1.t1 1791086400",
                                       "remind oh.thread.1.t1 1791086400 true"])
            #expect(MarkDoneIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        }
    }

    @Test func entitiesAndQueriesGoThroughTheBridge() async throws {
        try await withRecorder { recorder in
            let accounts = try await AccountQuery().suggestedEntities()
            #expect(accounts.map(\.title) == ["Work", "Personal"])
            #expect(try await AccountQuery().entities(for: ["2"]).map(\.id) == ["2"])
            let threads = try await ThreadQuery().entities(for: ["oh.thread.1.t1", "oh.thread.1.gone"])
            #expect(threads.map(\.id) == ["oh.thread.1.t1"])
            let entity = try #require(threads.first)
            #expect(entity.link.absoluteString == "openhuman://thread/me@example.com/t1")
            #expect(entity.accountName == "Work" && entity.isImportant && entity.isUnread)
            #expect(recorder.calls.isEmpty, "lookups are reads, not actions")
        }
    }

    @Test func theAppsChoicesMatchMailFeatures() {
        for value in MailboxAppEnum.allCases { #expect(value.value.rawValue == value.rawValue) }
        #expect(Set(MailboxAppEnum.allCases.map(\.rawValue)) == Set(IntentMailbox.allCases.map(\.rawValue)))
        #expect(UnreadKindAppEnum.allCases.map(\.value) == IntentUnreadKind.allCases)
        let types: [Any.Type] = [CountUnreadIntent.self, FindConversationsIntent.self, OpenMailboxIntent.self,
                                 OpenThreadIntent.self, SearchMailIntent.self, NewMessageIntent.self,
                                 OpenReviewQueueIntent.self, MarkDoneIntent.self, SnoozeIntent.self, RemindMeIntent.self]
        #expect(types.map { String(describing: $0) } == IntentCatalog.all.map(\.name))
        #expect(MailAppShortcuts.appShortcuts.count == 3)
    }
}
