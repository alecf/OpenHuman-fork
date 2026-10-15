import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SelectModeTests {
    let rows = (1...10).map { ThreadKey(account: AccountID(1), rowID: Int64($0), gmailThreadID: GmailThreadID("t\($0)")) }

    @Test func checkFromHereChecksTheCursorRowAndBelowThenEverythingOnTheSecondPress() {
        let selection = SelectionModel()
        selection.checkFromHere(cursor: rows[3], in: rows)
        #expect(selection.checked == Set(rows[3...]))
        #expect(rows[..<3].allSatisfy { !selection.checked.contains($0) })
        #expect(selection.offersCheckBefore(in: rows), "rows above are left to offer")
        selection.checkFromHere(cursor: rows[3], in: rows)
        #expect(selection.checked == Set(rows))
        #expect(!selection.offersCheckBefore(in: rows))
    }

    @Test func checkAllChecksEveryLoadedRowAndOffersNothingBefore() {
        let selection = SelectionModel()
        selection.checkAll(in: rows)
        #expect(selection.checked.count == 10)
        #expect(!selection.offersCheckBefore(in: rows))
        #expect(selection.headerCheck(in: rows) == .all)
    }

    @Test func extendingToTheEndOffersTheRowsAbove() {
        let selection = SelectionModel()
        selection.extend(to: rows[9], from: rows[3], in: rows)
        #expect(selection.offersCheckBefore(in: rows))
        selection.toggle(rows[5])
        #expect(!selection.offersCheckBefore(in: rows), "a gap is not a from-here selection")
    }

    @Test func aSelectionThatStopsShortOfTheEndOffersNothing() {
        let selection = SelectionModel()
        selection.extend(to: rows[6], from: rows[3], in: rows)
        #expect(!selection.offersCheckBefore(in: rows))
        selection.checkFromHere(cursor: rows[6], in: rows)
        #expect(selection.checked == Set(rows[6...]), "a fresh from-here selection replaces the old one")
    }

    @Test func withoutACursorCheckFromHereChecksEverything() {
        let selection = SelectionModel()
        selection.checkFromHere(cursor: nil, in: rows)
        #expect(selection.checked == Set(rows))
    }

    @Test func headerCheckFollowsTheSelection() {
        let selection = SelectionModel()
        #expect(selection.headerCheck(in: rows) == .hidden)
        selection.toggle(rows[0])
        #expect(selection.headerCheck(in: rows) == .some)
        selection.checkAll(in: rows)
        #expect(selection.headerCheck(in: rows) == .all)
        selection.clearChecked()
        #expect(selection.headerCheck(in: rows) == .hidden)
        #expect(selection.headerCheck(in: []) == .hidden)
    }

    @Test func dismissingTheHintLastsUntilTheSelectionClears() {
        let selection = SelectionModel()
        selection.checkFromHere(cursor: rows[3], in: rows)
        selection.checkBeforeHintDismissed = true
        selection.toggle(rows[3])
        selection.toggle(rows[3])
        #expect(selection.checkBeforeHintDismissed)
        selection.clearChecked()
        #expect(!selection.checkBeforeHintDismissed)
    }

    @Test func sidePanelShowsShortcutsOnlyWhileSomethingIsChecked() {
        #expect(ListSidePanel.state(checkedCount: 0) == .recentOpens)
        #expect(ListSidePanel.state(checkedCount: 1) == .shortcuts)
        #expect(ListSidePanel.state(checkedCount: 250) == .shortcuts)
        #expect(ListSidePanel.recentOpens.title == "Recent Opens" && ListSidePanel.shortcuts.title == "Shortcuts")
    }

    @Test func selectAllTipFollowsTheUsersBindings() {
        let rebound = ActionCatalog.all.compactMap { d -> ActionDescriptor? in
            if d.id == .checkFromHere { return nil }
            return d.id == .checkAll ? d.rebound([.chord("l", [.command, .option])]) : d
        }
        #expect(SelectAllShortcuts.tipRows(rebound) == [.init(title: "Select All", keycaps: ["⌥", "⌘", "L"])])
        #expect(SelectAllShortcuts.keycaps(for: SelectAllShortcuts.commandA, in: rebound).isEmpty)
    }

    @Test func keycapsAreSpokenAsKeyNames() {
        #expect(SelectAllShortcuts.spoken(["⌘", "shift", "A"]) == "Command Shift A")
        #expect(SelectAllShortcuts.spoken(["Esc"]) == "Escape")
        #expect(SelectAllShortcuts.spoken(["shift", "J"]) == "Shift J")
    }

    @Test func selectAllTipListsBothShortcutsWithKeycaps() {
        #expect(SelectAllShortcuts.tipRows() == [
            .init(title: "Select All", keycaps: ["⌘", "shift", "A"]),
            .init(title: "Select All From Here", keycaps: ["⌘", "A"]),
        ])
        #expect(SelectAllShortcuts.commandA == .checkFromHere && SelectAllShortcuts.commandShiftA == .checkAll)
        #expect(ActionCatalog.descriptor(.checkFromHere)?.defaultBindings == [.chord("a", .command)])
        #expect(ActionCatalog.descriptor(.checkAll)?.defaultBindings == [.chord("A", .command)])
        #expect(ActionCatalog.descriptor(.checkFromHere)?.allowsMenuKeyEquivalent == false)
    }

    @Test func shortcutsPanelStartsWithNavigationFromTheKeyTable() throws {
        let sections = SelectModeShortcuts.sections(ActionCatalog.all)
        let navigation = try #require(sections.first)
        #expect(navigation.title == "Navigation")
        #expect(navigation.items.map(\.title) == ["Next Conversation", "Previous Conversation", "Select Conversation"])
        #expect(navigation.items.map(\.keycaps) == [["J"], ["K"], ["X"]])
        let selection = try #require(sections.first { $0.title == "Selection" })
        #expect(selection.items.first { $0.title == "Select All" }?.keycaps == ["⌘", "shift", "A"])
        #expect(selection.items.first { $0.title == "Select Next" }?.keycaps == ["shift", "J"])
        let actions = try #require(sections.first { $0.title == "Actions" })
        #expect(actions.items.first?.title == "Mark Done")
        #expect(actions.items.contains { $0.title == "Mark as Spam" })
        #expect(!actions.items.contains { $0.title.hasSuffix("…") })
    }

    @Test func actionTitlesReadAsHeadlines() {
        #expect(SelectModeShortcuts.headline("Move to…") == "Move to")
        #expect(SelectModeShortcuts.headline("Mark read or unread") == "Mark Read or Unread")
        #expect(SelectModeShortcuts.headline("Snooze…") == "Snooze")
        #expect(SelectModeShortcuts.headline("Remind me…") == "Remind Me")
    }

    @Test func aRecentOpenNamesTheSenderWithoutTheMessageCount() {
        let recent = RecentOpens()
        let row = ThreadRow(id: rows[0], subject: "Plans", snippet: "s", participantsDisplay: "Alex Sample, me (3)",
                            participants: [], messageCount: 3, unreadCount: 0, draftCount: 0, attachmentCount: 0,
                            isUnread: false, isStarred: false, isImportant: false, userLabelIDs: [],
                            lastMessageAt: Date(timeIntervalSinceReferenceDate: 0), sortAt: Date(timeIntervalSinceReferenceDate: 0))
        recent.record(row, at: Date(timeIntervalSinceReferenceDate: 60))
        #expect(recent.entries.first?.sender == "Alex Sample, me")
    }

    @Test func recentOpensKeepsOneEntryPerConversationNewestFirst() {
        let recent = RecentOpens()
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        recent.record(.init(id: rows[0], sender: "Alex Sample", subject: "Plans", openedAt: start))
        recent.record(.init(id: rows[1], sender: "Pat Example", subject: "Notes", openedAt: start + 60))
        recent.record(.init(id: rows[0], sender: "Alex Sample", subject: "Plans", openedAt: start + 120))
        #expect(recent.entries.map(\.id) == [rows[0], rows[1]])
        for index in 0..<(RecentOpens.limit + 5) {
            let key = ThreadKey(account: AccountID(2), rowID: Int64(index), gmailThreadID: GmailThreadID("r\(index)"))
            recent.record(.init(id: key, sender: "Sam Placeholder", subject: "Item", openedAt: start + Double(index)))
        }
        #expect(recent.entries.count == RecentOpens.limit)
    }

    @Test func recentOpensGroupByRecency() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2030, month: 3, day: 14, hour: 20)))
        func entry(_ index: Int, hoursAgo: Double) -> RecentOpens.Entry {
            .init(id: rows[index], sender: "Sender \(index)", subject: "Subject \(index)", openedAt: now - hoursAgo * 3600)
        }
        let entries = [entry(0, hoursAgo: 11), entry(1, hoursAgo: 0.25), entry(2, hoursAgo: 1), entry(3, hoursAgo: 26),
                       entry(4, hoursAgo: 24 * 4), entry(5, hoursAgo: 24 * 30), entry(6, hoursAgo: 0)]
        let groups = RecentOpenGroup.groups(entries, now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        #expect(groups.map(\.kind) == [.recent, .yesterday, .lastSevenDays, .earlier])
        #expect(groups.map(\.title) == [nil, "Yesterday", "Last 7 days", "Earlier"])
        #expect(groups[0].lines.map(\.entry.id) == [rows[6], rows[1], rows[2], rows[0]])
        #expect(groups[0].lines.map(\.stamp) == ["Just now", "15 min ago", "1 hr ago", "11 hrs ago"])
        #expect(groups[1].lines.map(\.entry.id) == [rows[3]])
        #expect(groups[1].lines[0].stamp.hasPrefix("Wed"))
        #expect(groups[2].lines[0].stamp.hasPrefix("Sun"))
        #expect(groups[3].lines.map(\.entry.id) == [rows[5]])
    }

    @Test func listModelCheckFromHereUsesTheCursor() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let list = try #require(f.router.list)
        let keys = f.rows.map(\.id)
        list.setCursor(keys[3])
        list.checkFromHere()
        #expect(list.selection.checked == Set(keys[3...]))
        #expect(list.offersCheckBefore && list.headerCheck == .some)
        list.selection.checkBeforeHintDismissed = true
        #expect(!list.offersCheckBefore)
        list.headerCheckClicked()
        #expect(list.headerCheck == .all)
        list.headerCheckClicked()
        #expect(list.headerCheck == .hidden && list.selection.checked.isEmpty)
    }

    @Test func commandAThroughTheRouterChecksFromHereThenEverything() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let state = try #require(f.router.active)
        let keys = f.rows.map(\.id)
        f.router.list?.setCursor(keys[4])
        #expect(await f.run(SelectAllShortcuts.commandA))
        #expect(state.selection.checked == Set(keys[4...]))
        #expect(await f.run(SelectAllShortcuts.commandA))
        #expect(state.selection.checked == Set(keys))
        #expect(await f.run(.clearChecks))
        #expect(await f.run(SelectAllShortcuts.commandShiftA))
        #expect(state.selection.checked == Set(keys))
    }

    @Test func aFailedBatchWriteClearsTheChecksAtOnceAndBringsThemBack() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let state = try #require(f.router.active)
        let keys = f.rows.map(\.id)
        state.selection.toggle(keys[1])
        state.selection.toggle(keys[2])
        f.store.failNextCommand()
        #expect(f.registry.perform(.trash, source: .keyboard, host: f.router))
        #expect(state.selection.checked.isEmpty, "the checks clear before the write")
        await f.registry.lastTask?.value
        #expect(state.selection.checked == [keys[1], keys[2]], "the failed write puts them back")
        await untilObserved { f.rows.contains { $0.id == keys[1] } && f.rows.contains { $0.id == keys[2] } }
    }

    @Test func openingAConversationRecordsItAsARecentOpen() async throws {
        let f = ActionFixture()
        await untilObserved { f.router.list?.state == .loaded && f.rows.count == 10 }
        let keys = f.rows.map(\.id)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        f.router.recentOpens.now = { first }
        f.router.open(keys[2])
        f.router.closeReader()
        f.router.recentOpens.now = { first.addingTimeInterval(90) }
        f.router.open(keys[5])
        #expect(f.router.recentOpens.entries.map(\.id) == [keys[5], keys[2]])
        #expect(f.router.recentOpens.entries.last?.subject == f.rows[2].subject)
        #expect(f.router.recentOpens.entries.map(\.openedAt) == [first.addingTimeInterval(90), first],
                "opens are stamped by the recent-opens clock")
    }
}
