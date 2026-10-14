import Foundation
import OpenHumanCore
import Testing
@testable import MailModel

@Test func threadKeyEqualityIgnoresGmailID() {
    let a = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("x"))
    let b = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("y"))
    let c = ThreadKey(account: AccountID(2), rowID: 7, gmailThreadID: GmailThreadID("x"))
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
    #expect(a != c)
}

@Test func messageKeyEqualityIgnoresGmailID() {
    let a = MessageKey(account: AccountID(1), rowID: 3, gmailMessageID: GmailMessageID("m1"))
    let b = MessageKey(account: AccountID(1), rowID: 3, gmailMessageID: GmailMessageID("m2"))
    #expect(a == b)
    #expect(Set([a, b]).count == 1)
}

private let packagesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func declaredNames(in folder: URL, topLevelOnly: Bool) throws -> Set<String> {
    let pattern = topLevelOnly
        ? try Regex(#"(?m)^(?:public |internal |package )?(?:final |indirect )?(?:struct|enum|protocol|class|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        : try Regex(#"(?:struct|enum|protocol|class|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
    var names = Set<String>()
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return names }
    for case let file as URL in files where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in text.matches(of: pattern) {
            if let name = match.output[1].substring { names.insert(String(name)) }
        }
    }
    return names
}

@Test func noNameClashWithDataLayerContracts() throws {
    let ours = try declaredNames(in: packagesRoot.appendingPathComponent("OpenHumanMailCore/Sources/MailModel"),
                                 topLevelOnly: true)
    #expect(ours.isSuperset(of: ["ThreadKey", "MailDataSource", "MailCommanding", "AccountManaging", "SettingsPort",
                                 "DraftSummary", "LabelInfo", "AppSettingKey", "ReminderItem", "SnoozeState"]),
            "the MailModel scan found \(ours.sorted())")
    var declared = Set<String>()
    for folder in ["OpenHumanStore/Sources/OpenHumanStore/Contracts", "OpenHumanGmail/Sources/OpenHumanGmail/Contracts",
                   "OpenHumanGmail/Sources/OpenHumanMIME/Contracts", "OpenHumanSync/Sources/OpenHumanSync/Contracts"] {
        declared.formUnion(try declaredNames(in: packagesRoot.appendingPathComponent(folder), topLevelOnly: false))
    }
    #expect(declared.contains("ThreadWindow") && declared.contains("SettingKey"),
            "contracts folders not found from \(packagesRoot.path)")
    let clashes = ours.intersection(declared)
    #expect(clashes.isEmpty, "MailModel names clash with data-layer contracts: \(clashes.sorted())")
}

@Test func mailCommandRoundTripsThroughCodable() throws {
    let key = ThreadKey(account: AccountID(1), rowID: 9, gmailThreadID: GmailThreadID("t9"))
    let commands: [MailCommand] = [
        .markDone([key]), .modifyLabels([key], add: [GmailLabelID("Label_1")], remove: [GmailLabelID("INBOX")]),
        .snooze([key], until: Date(timeIntervalSince1970: 1_800_000_000)), .unsnooze([key]),
        .setReminder(key, dueAt: Date(timeIntervalSince1970: 1_800_000_060), kind: .ifNoReply), .cancelReminder(key),
    ]
    let data = try JSONEncoder().encode(commands)
    #expect(try JSONDecoder().decode([MailCommand].self, from: data) == commands)
    #expect(commands.map(\.name) == ["markDone", "modifyLabels", "snooze", "unsnooze", "setReminder", "cancelReminder"])
    #expect(commands.allSatisfy { $0.threads == [key] })
}

@Test func locationsRoundTripAndKnowTheirOrder() throws {
    let locations: [MailLocation] = [
        .split(SplitKey("s1")), .splitOther, .system(.inbox), .label(GmailLabelID("Label_3")),
        .reviewQueue(nil), .reviewQueue([DraftKey("d1")]), .search("from:dana is:unread"),
    ]
    let data = try JSONEncoder().encode(locations)
    #expect(try JSONDecoder().decode([MailLocation].self, from: data) == locations)
    #expect(MailLocation.system(.snoozed).sortsAscending)
    #expect(MailLocation.system(.reminders).sortsAscending)
    #expect(MailLocation.system(.scheduled).sortsAscending)
    #expect(MailLocation.system(.waiting).sortsAscending, "schema v2 (B28): oldest send first")
    #expect(!MailLocation.system(.inbox).sortsAscending)
    #expect(Set(SystemFolder.allCases.map(\.rawValue)) == ["inbox", "starred", "important", "unread", "sent", "drafts",
                                                          "allMail", "trash", "spam", "snoozed", "scheduled", "reminders",
                                                          "done", "waiting"])
}

@Test func safeModeAllowsChangesExceptReadOnly() {
    #expect(SafeModeInfo.normal.allowsMailChanges)
    #expect(SafeModeInfo.writeAllowlist.allowsMailChanges)
    #expect(!SafeModeInfo.readOnly.allowsMailChanges)
}

@Test func aStoredUndoSendValueIsClampedIntoTheSettingsRange() {
    #expect(AppSettings.undoSendSecondsRange == 0...60)
    #expect(AppSettings.undoSendHold(Int.max) == 60)
    #expect(AppSettings.undoSendHold(61) == 60)
    #expect(AppSettings.undoSendHold(30) == 30)
    #expect(AppSettings.undoSendHold(0) == 0)
    #expect(AppSettings.undoSendHold(-5) == 0)
    #expect(AppSettings.undoSendHold(Int.min) == 0)
}

@Test func settingKeysMatchTheStore() {
    #expect(AppSettings.undoSendSeconds.name == "undo_send_seconds" && AppSettings.undoSendSeconds.defaultValue == 10)
    #expect(AppSettings.defaultAccount.name == "default_account" && AppSettings.defaultAccount.defaultValue == nil)
    #expect(AppSettings.snoozeMarkUnread.name == "snooze_mark_unread" && AppSettings.snoozeMarkUnread.defaultValue)
    #expect([AppSettings.schedulerSnooze, AppSettings.schedulerSendLater, AppSettings.schedulerReminders].map(\.name)
        == ["scheduler.snooze.enabled", "scheduler.send_later.enabled", "scheduler.reminders.enabled"])
    #expect(AppSettings.cliReadonlyDefault.isSafetyKey && AppSettings.cliAllowedCommands.isSafetyKey)
    #expect(!AppSettings.undoSendSeconds.isSafetyKey)
    let images = AppSettings.remoteImages(AccountID(2))
    #expect(images.name == "remote_images" && images.scope == .account(AccountID(2)) && images.defaultValue == .block)
    #expect(AppSettings.remoteImageSenders(AccountID(2)).name == "remote_images.allowed_senders")
    #expect(AppSettings.remoteImages(AccountID(1)) != AppSettings.remoteImages(AccountID(2)))
    #expect(RemoteImagePolicy.allCases.map(\.rawValue) == ["block", "ask", "allow"])
    #expect(ScheduleKindName.allCases.map(\.rawValue) == ["snooze", "send_later", "reminder"])
}

@Test func draftSummaryRules() {
    let base = DraftSummary(id: DraftKey("d"), account: AccountID(1), mode: .new, fields: DraftFields(), updatedAt: .now)
    #expect(!base.isAgentDraft && base.canBeScheduled)
    let agent = DraftSummary(id: DraftKey("a"), account: AccountID(1), mode: .reply, fields: DraftFields(),
                             source: .agent, review: .pending, updatedAt: .now)
    #expect(agent.isAgentDraft && !agent.canBeScheduled)
    let kept = DraftSummary(id: DraftKey("k"), account: AccountID(1), mode: .reply, fields: DraftFields(),
                            source: .cli, review: .approved, updatedAt: .now)
    #expect(kept.canBeScheduled)
}

@Test func smallValueHelpers() {
    let wake = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(SnoozeState.until(wake, stampCount: 2).wakeAt == wake)
    #expect(SnoozeState.wakeTimeUnknown.wakeAt == nil)
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t"))
    #expect(ReminderItem(id: "r1", thread: key, subject: "s", dueAt: wake, kind: .always).notificationIdentifier == "reminder.r1")
    let counts = MailboxCountsInfo(account: AccountID(1), byLabel: [:], inboxUnread: 7,
                                   splitUnread: [SplitKey("a"): 2, SplitKey("b"): 1], draftsCount: 0,
                                   pendingReviewCount: 0, failedOperationCount: 0)
    #expect(counts.otherUnread == 4)
    #expect(SnippetInfo(name: "n", bodyHTML: "b").isNew)
    #expect(MailPortError.blockedBySafeMode.description == "Read-only: Mail can't change your mail")
    #expect(MailPortError.blockedBySafeMode.description == MailPortError.readOnlyText)
}

@Test func unimplementedMembersFailLoudly() async throws {
    struct Minimal: MailDataSource {
        func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
        func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { AsyncThrowingStream { $0.finish() } }
        func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { AsyncThrowingStream { $0.finish() } }
    }
    let source = Minimal()
    #expect(source.safeMode() == .normal)
    await #expect(throws: MailPortError.unsupported("labels")) {
        for try await _ in source.labels(AccountID(1)) {}
    }
    await #expect(throws: MailPortError.unsupported("diagnosticsSnapshot")) { _ = try await source.diagnosticsSnapshot() }
    await #expect(throws: MailPortError.unsupported("sentConversation")) {
        _ = try await source.sentConversation(DraftKey("d1"))
    }
    await #expect(throws: MailPortError.unsupported("searchGmail")) { _ = try await source.searchGmail("x", account: AccountID(1)) }
    var connectivity = source.connectivity().makeAsyncIterator()
    #expect(await connectivity.next() == nil)
}

@Test func importancePortEditsDefaultToUnsupported() async throws {
    struct Minimal: ImportanceRulesPort {
        func apply(_ change: ImportanceChange) async throws -> UndoToken { UndoToken(payload: Data()) }
        func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation {
            ImportanceExplanation(isImportant: false, placement: "Other", reason: "No rule matched")
        }
        func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func undo(_ token: UndoToken) async throws -> UndoToken? { nil }
    }
    let change = ImportanceChange(kind: .neverDomain, account: AccountID(1), value: "Example.com")
    #expect(change.value == "example.com" && change.effect == .neverImportant && change.kind.match == .domain)
    await #expect(throws: MailPortError.unsupported("editing importance rules")) {
        try await Minimal().update("1", to: change)
    }
    await #expect(throws: MailPortError.unsupported("deleting importance rules")) { try await Minimal().delete(["1"]) }
    #expect(ImportanceRuleMatch.allCases == [.sender, .thread, .domain, .label, .keyword, .matcher], "specificity order")
    #expect(ImportanceRuleKind.allCases.filter { $0.impliedEffect == nil } == [.keyword, .label, .matcher])
}

@Test func searchCoverageDefaultsToComplete() {
    #expect(ThreadListWindow(rows: [], hasMore: false, totalCount: 0).search == nil)
    #expect(SearchResultsInfo(hits: [], hasMore: false).completeness.isComplete)
    let status = SearchWindowStatus()
    #expect(status.completeness == .complete && status.gmail == .notAsked && !status.gmailAvailable)
    #expect(!SearchCompletenessInfo(reasons: [.tooManyMatches(limit: 20_000)]).isComplete)
}

@Test func otherTotalUsesTheStoresOtherRowElseTheInboxMinusTheSplits() {
    let account = AccountID(1)
    func label(_ id: Int64, _ key: String, total: Int) -> LabelInfo {
        LabelInfo(id: id, account: account, labelID: GmailLabelID(key), kind: .system, name: key, displayName: key, position: 0,
                  totalThreads: total)
    }
    let split = SplitInfo(id: SplitKey("s1"), account: account, name: "Important", position: 0, ruleText: "is:important",
                          unreadThreads: 2, totalThreads: 115)
    let disabled = SplitInfo(id: SplitKey("s2"), account: account, name: "Old", position: 1, ruleText: "x", enabled: false,
                             totalThreads: 9)
    let counts = MailboxCountsInfo(account: account, byLabel: [:], inboxUnread: 40, splitUnread: [split.id: 2], draftsCount: 0,
                                   pendingReviewCount: 0, failedOperationCount: 0)
    #expect(counts.otherUnread == 38)
    #expect(counts.otherTotal(labels: [], splits: [split]) == nil, "unknown until the labels arrive")
    #expect(counts.otherTotal(labels: [label(1, "INBOX", total: 4_713)], splits: [split, disabled]) == 4_598)
    #expect(counts.otherTotal(labels: [label(1, "INBOX", total: 4_713), label(2, "oh:split:other", total: 4_598)],
                              splits: [split]) == 4_598)
}
