import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private let format = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))
private let now = Date(timeIntervalSince1970: 1_791_640_800)
private let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t"))

private func row(important: Bool = false, categories: [Int64] = [], labels: [Int64] = [], starred: Bool = false,
                 attachments: Int = 0, drafts: Int = 0, reminderAt: Date? = nil, snoozedUntil: Date? = nil,
                 pending: Bool = false, returned: Bool = false) -> ThreadRow {
    ThreadRow(id: key, subject: "Q4 budget", snippet: "Updated numbers\nattached", participantsDisplay: "Dana Ruiz",
              participants: [], messageCount: 1, unreadCount: 1, draftCount: drafts, attachmentCount: attachments,
              isUnread: true, isStarred: starred, isImportant: important, userLabelIDs: labels,
              lastMessageAt: now.addingTimeInterval(-3_600), sortAt: now.addingTimeInterval(-3_600),
              snoozedUntil: snoozedUntil, reminderAt: reminderAt, hasPendingChanges: pending,
              categoryLabelIDs: categories, returnedByReminder: returned)
}

private let labels: [Int64: LabelInfo] = [
    10: LabelInfo(id: 10, account: AccountID(1), labelID: GmailLabelID("CATEGORY_PROMOTIONS"), kind: .category,
                  name: "Promotions", displayName: "Promotions", position: 0),
    20: LabelInfo(id: 20, account: AccountID(1), labelID: GmailLabelID("Label_20"), kind: .user, name: "Finance",
                  displayName: "Finance", colorBackground: "#16a766", position: 1),
    21: LabelInfo(id: 21, account: AccountID(1), labelID: GmailLabelID("Label_21"), kind: .user, name: "Work/Planning",
                  displayName: "Planning", position: 2),
    22: LabelInfo(id: 22, account: AccountID(1), labelID: GmailLabelID("Label_22"), kind: .user, name: "Travel",
                  displayName: "Travel", position: 3),
]

@Test func importanceComesFirstAndACategoryNeverHidesIt() {
    let context = ThreadRowChipContext(location: .system(.inbox), labels: labels)
    let chips = ThreadRowFormatting.chips(for: row(important: true, categories: [10], labels: [20, 21, 22]), context: context)
    #expect(chips.map(\.kind) == [.important, .category, .label, .label, .overflow])
    #expect(chips.map(\.title) == ["Important", "Promotions", "Finance", "Planning", "+1"])
    #expect(chips[2].color == "#16a766")
    #expect(ThreadRowFormatting.chips(for: row(categories: [10], labels: [20]), context: context).map(\.kind)
        == [.category, .label])
}

@Test func theLocationsOwnMeaningIsNotRepeated() {
    let important = ThreadRowChipContext(location: .system(.important), labels: labels, impliesImportance: true)
    #expect(ThreadRowFormatting.chips(for: row(important: true, categories: [10]), context: important).map(\.kind) == [.category])
    let finance = ThreadRowChipContext(location: .label(GmailLabelID("Label_20")), labels: labels)
    #expect(ThreadRowFormatting.chips(for: row(labels: [20, 21]), context: finance).map(\.title) == ["Planning"])
    let promotions = ThreadRowChipContext(location: .label(GmailLabelID("CATEGORY_PROMOTIONS")), labels: labels)
    #expect(ThreadRowFormatting.chips(for: row(important: true, categories: [10]), context: promotions).map(\.kind) == [.important])
    #expect(ThreadRowFormatting.ruleImpliesImportance(" is:important "))
    #expect(!ThreadRowFormatting.ruleImpliesImportance("is:important OR from:(@acme.example)"))
}

@Test func unknownLabelsShowNoChip() {
    let context = ThreadRowChipContext(location: .system(.inbox))
    #expect(ThreadRowFormatting.chips(for: row(important: true, categories: [10], labels: [20]), context: context).map(\.kind)
        == [.important])
}

@Test func indicatorsByPriority() {
    let soon = now.addingTimeInterval(86_400)
    let all = row(starred: true, attachments: 2, drafts: 1, reminderAt: soon, snoozedUntil: soon, pending: true)
    #expect(ThreadRowFormatting.indicators(for: all, location: .system(.inbox), now: now)
        == [.starred, .reminder, .snoozed, .draft, .attachment, .pending])
    #expect(!ThreadRowFormatting.indicators(for: all, location: .system(.reminders), now: now).contains(.reminder))
    #expect(!ThreadRowFormatting.indicators(for: all, location: .system(.snoozed), now: now).contains(.snoozed))
}

@Test func dateColumnShowsTheComingTimeInScheduleViews() {
    let wake = Date(timeIntervalSince1970: 1_791_878_400)
    let snoozed = format.dateColumn(row(snoozedUntil: wake), location: .system(.snoozed), now: now)
    #expect(snoozed.isUpcoming)
    #expect(snoozed.text.hasPrefix("TUE") && snoozed.text.contains("8:00"), "weekday and time: \(snoozed.text)")
    let inbox = format.dateColumn(row(snoozedUntil: wake), location: .system(.inbox), now: now)
    #expect(inbox.text == "1:00\u{202F}PM" && !inbox.isUpcoming)
}

@Test func voiceOverReadsTheWholeRow() {
    let context = ThreadRowChipContext(location: .system(.inbox), labels: labels)
    let r = row(important: true, categories: [10], labels: [20], starred: true, attachments: 1)
    let label = format.accessibilityLabel(r, chips: ThreadRowFormatting.chips(for: r, context: context),
                                          location: .system(.inbox), now: now)
    #expect(label == "Unread, Dana Ruiz, Q4 budget, 1:00\u{202F}PM, has attachment, starred, important, "
            + "category Promotions, label Finance, Updated numbers attached")
}

@Test func aReturnedReminderLeadsTheChipsWithItsExactWording() {
    let context = ThreadRowChipContext(location: .system(.inbox), labels: labels)
    let chips = ThreadRowFormatting.chips(for: row(important: true, categories: [10], labels: [20, 21, 22], returned: true),
                                          context: context)
    #expect(chips.map(\.kind) == [.returned, .important, .category, .label, .label, .overflow])
    #expect(chips.first?.title == "Reminder returned")
    #expect(ThreadRowChip.reminderReturned == ThreadRowChip(kind: .returned, title: "Reminder returned"))
    #expect(!ThreadRowFormatting.chips(for: row(important: true), context: context).contains { $0.kind == .returned })
    let starred = ThreadRowChipContext(location: .system(.starred), labels: labels)
    #expect(ThreadRowFormatting.chips(for: row(returned: true), context: starred).map(\.kind) == [.returned])
}

@Test func theVIPChipFollowsAReturnedReminder() {
    let important = ThreadRowChip(kind: .important, title: "Important")
    #expect(ThreadRowFormatting.withVIPChip([.reminderReturned, important], title: "VIP").map(\.kind)
        == [.returned, .vip, .important])
    #expect(ThreadRowFormatting.withVIPChip([important], title: "VIP").map(\.kind) == [.vip, .important])
    #expect(ThreadRowFormatting.withVIPChip([], title: "VIP") == [ThreadRowChip(kind: .vip, title: "VIP")])
}

@Test func voiceOverReadsTheReturnedReminderWordForWord() {
    let context = ThreadRowChipContext(location: .system(.inbox), labels: labels)
    let r = row(labels: [20], returned: true)
    let label = format.accessibilityLabel(r, chips: ThreadRowFormatting.chips(for: r, context: context),
                                          location: .system(.inbox), now: now)
    #expect(label == "Unread, Dana Ruiz, Q4 budget, 1:00\u{202F}PM, Reminder returned, label Finance, Updated numbers attached")
}

@Test func emptyStates() {
    func make(_ location: MailLocation, title: String = "Inbox", state: ThreadListModel.LoadState = .loaded,
              loadingShown: Bool = false, connectivity: ConnectivityState? = nil, day: Int = 0) -> ThreadListEmptyState? {
        ThreadListEmptyState.make(location: location, locationTitle: title, state: state, hasRows: false,
                                  loadingShown: loadingShown, connectivity: connectivity, day: day)
    }
    #expect(ThreadListEmptyState.make(location: .system(.inbox), locationTitle: "Inbox", state: .loaded, hasRows: true,
                                      loadingShown: true, connectivity: nil, day: 0) == nil)
    #expect(make(.system(.inbox), state: .loading)?.style == .blank, "no spinner before 150 ms")
    #expect(make(.system(.inbox), state: .loading, loadingShown: true)?.title == "Loading…")
    #expect(make(.system(.inbox), connectivity: .online(syncing: true, lastSyncAt: nil))?.title == "Fetching your mail…")
    let inbox = make(.system(.inbox), day: 3)
    #expect(inbox?.style == .inboxClear && inbox == make(.system(.inbox), day: 4), "one calm line, the same every day")
    #expect(inbox?.title == "Inbox zero." && inbox?.subtitle == nil && inbox?.symbol == "tray")
    #expect(make(.split(SplitKey("team")), title: "Team")?.title == "Nothing in Team.")
    #expect(make(.splitOther, title: "Other")?.title == "Nothing in Other.")
    #expect(make(.split(SplitKey("team")), title: "GitHub")?.subtitle == nil, "no playful second line")
    #expect(make(.search("zz"))?.symbol == "magnifyingglass")
    #expect(make(.system(.trash))?.symbol == "tray" && make(.system(.drafts))?.symbol == "tray")
    #expect(make(.system(.reminders))?.detail == "Reminders stay on this Mac.")
    #expect(make(.system(.drafts))?.title == "No drafts.")
    #expect(make(.reviewQueue(nil))?.title == "No drafts waiting.")
    #expect(make(.system(.inbox), state: .failed("x"))?.style == .failure)
    #expect(make(.system(.starred), connectivity: .offline(since: nil))?.detail?.contains("offline") == true)
}

@Test func mutedRowsLeadWithTheMutedIndicator() {
    let r = row(starred: true, attachments: 1)
    #expect(ThreadRowFormatting.indicators(for: r, location: .system(.inbox), now: now, muted: true).first == .muted)
    #expect(!ThreadRowFormatting.indicators(for: r, location: .system(.inbox), now: now).contains(.muted))
    #expect(ThreadRowIndicator.muted.symbol == "speaker.slash")
    let label = format.accessibilityLabel(r, chips: [], location: .system(.inbox), now: now, includeSnippet: false,
                                          muted: true)
    #expect(label.contains("muted"), "\(label)")
}

@Test func snoozedRowWithoutAWakeTimeStillShowsTheClock() {
    #expect(ThreadRowFormatting.indicators(for: row(), location: .system(.snoozed), now: now).contains(.snoozed))
    #expect(!ThreadRowFormatting.indicators(for: row(), location: .system(.inbox), now: now).contains(.snoozed))
}

@Test func comingTimesAreUppercasedAndSpokenInNormalCase() {
    let later = Date(timeIntervalSince1970: 1_792_310_400)
    #expect(format.upcomingDate(later, now: now) == "OCT 18")
    #expect(format.spokenUpcomingDate(later, now: now) == "Oct 18")
    let today = now.addingTimeInterval(3_600)
    #expect(format.upcomingDate(today, now: now) == format.spokenUpcomingDate(today, now: now))
    let label = format.accessibilityLabel(row(snoozedUntil: later), chips: [], location: .system(.snoozed), now: now,
                                          includeSnippet: false)
    #expect(label.contains("until Oct 18"), "\(label)")
}
