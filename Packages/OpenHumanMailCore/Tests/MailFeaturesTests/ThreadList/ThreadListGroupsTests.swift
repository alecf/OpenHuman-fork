import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let format = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))

private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private let now = day(2026, 10, 20, 15)

private func thread(_ n: Int64, _ at: Date) -> ThreadRow {
    ThreadRow(id: ThreadKey(account: AccountID(1), rowID: n, gmailThreadID: GmailThreadID("t\(n)")), subject: "S\(n)",
              snippet: "s", participantsDisplay: "P\(n)", participants: [], messageCount: 1, unreadCount: 0, draftCount: 0,
              attachmentCount: 0, isUnread: false, isStarred: false, isImportant: false, userLabelIDs: [],
              lastMessageAt: at, sortAt: at)
}

private enum Cell: Equatable {
    case thread(Int64)
    case header(ThreadDateGroup)
    case placeholder
}

private func cells(_ snapshot: ThreadListSnapshot, _ groups: ThreadListGroups) -> [Cell] {
    (0..<groups.displayCount(rows: snapshot.displayCount)).map { display in
        switch groups.item(atDisplay: display) {
        case .header(let index): .header(groups.headers[index].group)
        case .row(let row): row < snapshot.rows.count ? .thread(snapshot.rows[row].id.rowID) : .placeholder
        }
    }
}

private func applied(_ change: ThreadListChange, old: [Cell], new: [Cell]) -> [Cell] {
    guard case .update(let edit) = change else { return new }
    var table = old
    for index in edit.removed.reversed() { table.remove(at: index) }
    for index in edit.inserted { table.insert(new[index], at: index) }
    for index in edit.reconfigured where index < table.count { table[index] = new[index] }
    return table
}

@Suite struct ThreadListGroupsTests {
    @Test func groupsAndTheirWords() {
        #expect(format.dateGroup(day(2026, 10, 20, 1), now: now) == .today)
        #expect(format.dateGroup(day(2026, 10, 21), now: now) == .today, "a date ahead of the clock is today's")
        #expect(format.dateGroup(day(2026, 10, 19, 23), now: now) == .yesterday)
        #expect(format.dateGroup(day(2026, 10, 14, 0), now: now) == .lastSevenDays)
        #expect(format.dateGroup(day(2026, 10, 13, 23), now: now) == .thisMonth)
        #expect(format.dateGroup(day(2026, 10, 1), now: now) == .thisMonth)
        #expect(format.dateGroup(day(2026, 9, 30), now: now) == .month(year: 2026, month: 9))
        #expect(format.dateGroup(day(2025, 8, 3), now: now) == .month(year: 2025, month: 8))
        #expect(format.groupTitle(.yesterday, now: now) == "Yesterday")
        #expect(format.groupTitle(.lastSevenDays, now: now) == "Last 7 days")
        #expect(format.groupTitle(.thisMonth, now: now) == "This month")
        #expect(format.groupTitle(.month(year: 2026, month: 9), now: now) == "September")
        #expect(format.groupTitle(.month(year: 2025, month: 8), now: now) == "August 2025")
        let third = day(2026, 10, 3, 9)
        #expect(format.dateGroup(day(2026, 10, 1), now: third) == .lastSevenDays)
        #expect(format.dateGroup(day(2026, 9, 27, 1), now: third) == .lastSevenDays)
        #expect(format.dateGroup(day(2026, 9, 26, 23), now: third) == .month(year: 2026, month: 9))
    }

    @Test func headersSitBeforeEachGroupsFirstThreadAndNeverForToday() {
        let rows = [thread(1, day(2026, 10, 20, 9)), thread(2, day(2026, 10, 20, 8)), thread(3, day(2026, 10, 19)),
                    thread(4, day(2026, 10, 16)), thread(5, day(2026, 10, 2)), thread(6, day(2026, 9, 30)),
                    thread(7, day(2026, 9, 2)), thread(8, day(2025, 8, 2))]
        let groups = ThreadListGroups.make(rows: rows, format: format, now: now)
        #expect(groups.headers.map(\.group) == [.yesterday, .lastSevenDays, .thisMonth, .month(year: 2026, month: 9),
                                                .month(year: 2025, month: 8)])
        #expect(groups.headers.map(\.row) == [2, 3, 4, 5, 7])
        #expect(groups.headers.map(\.title) == ["Yesterday", "Last 7 days", "This month", "September", "August 2025"])
        let snapshot = ThreadListSnapshot(rows: rows, placeholderCount: 2, totalCount: 10, hasMore: true)
        #expect(cells(snapshot, groups) == [.thread(1), .thread(2), .header(.yesterday), .thread(3), .header(.lastSevenDays),
                                            .thread(4), .header(.thisMonth), .thread(5), .header(.month(year: 2026, month: 9)),
                                            .thread(6), .thread(7), .header(.month(year: 2025, month: 8)), .thread(8),
                                            .placeholder, .placeholder])
        for row in 0..<10 { #expect(groups.item(atDisplay: groups.displayIndex(ofRow: row)) == .row(row)) }
        for (index, header) in groups.headers.enumerated() {
            #expect(groups.item(atDisplay: groups.displayIndex(ofHeader: index)) == .header(index))
            #expect(groups.rowIndex(atOrAfterDisplay: groups.displayIndex(ofHeader: index)) == header.row)
        }
        let older = ThreadListGroups.make(rows: Array(rows[2...]), format: format, now: now)
        #expect(older.headers.first?.row == 0 && older.headers.first?.group == .yesterday)
        #expect(ThreadListGroups.make(rows: [], format: format, now: now).isEmpty)
    }

    @Test(arguments: 0..<5)
    func everyEditKeepsTheTableInStep(scenario: Int) {
        let today = day(2026, 10, 20, 9), yesterday = day(2026, 10, 19), lastWeek = day(2026, 10, 16)
        let september = day(2026, 9, 10)
        let (old, new): (ThreadListSnapshot, ThreadListSnapshot) = switch scenario {
        case 0:
            (ThreadListSnapshot(rows: [thread(3, yesterday), thread(4, lastWeek)]),
             ThreadListSnapshot(rows: [thread(1, today), thread(3, yesterday), thread(4, lastWeek)]))
        case 1:
            (ThreadListSnapshot(rows: [thread(1, today), thread(3, yesterday), thread(6, september)]),
             ThreadListSnapshot(rows: [thread(1, today), thread(6, september)]))
        case 2:
            (ThreadListSnapshot(rows: [thread(1, today), thread(3, yesterday), thread(5, yesterday)]),
             ThreadListSnapshot(rows: [thread(3, day(2026, 10, 20, 10)), thread(1, today), thread(5, yesterday)]))
        case 3:
            (ThreadListSnapshot(rows: [thread(1, today), thread(3, yesterday)], placeholderCount: 3, totalCount: 5,
                                hasMore: true),
             ThreadListSnapshot(rows: [thread(1, today), thread(3, yesterday), thread(4, lastWeek), thread(6, september),
                                       thread(7, september)], placeholderCount: 0, totalCount: 5, hasMore: false))
        default:
            (ThreadListSnapshot(rows: [thread(3, yesterday)]), ThreadListSnapshot(rows: [thread(3, today)]))
        }
        let before = ThreadListGroups.make(rows: old.rows, format: format, now: now)
        let after = ThreadListGroups.make(rows: new.rows, format: format, now: now)
        let rowEdit = ThreadListEdit.between(old, new)
        let change = ThreadListGroups.translate(rowEdit, from: before, to: after)
        guard case .update(let edit) = change else {
            Issue.record("scenario \(scenario): a small change stays incremental")
            return
        }
        let oldCells = cells(old, before), newCells = cells(new, after)
        #expect(oldCells.count - edit.removed.count + edit.inserted.count == newCells.count, "scenario \(scenario)")
        #expect(applied(change, old: oldCells, new: newCells) == newCells, "scenario \(scenario)")
    }

    @Test func withoutHeadersTheEditIsTheRowsEdit() {
        let edit = ThreadListChange.update(ThreadListEdit(removed: IndexSet(integer: 2)))
        #expect(ThreadListGroups.translate(edit, from: .none, to: .none) == edit)
        #expect(ThreadListGroups.translate(.reload, from: .none, to: .none) == .reload)
    }
}

@MainActor
@Suite struct ThreadListModelGroupTests {
    @Test func theModelPlacesHeadersAndKeepsTheCursorOnThreads() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 60, now: fixedNow), options: .init())
        let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1), now: { fixedNow })
        model.groupFormatting = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))
        model.start()
        await eventually { model.rows.count == 60 }
        #expect(model.groups.isEmpty && model.displayCount == 60, "off until the list view turns it on")

        model.groupsByDate = true
        #expect(!model.groups.isEmpty, "the fake corpus spans several days")
        #expect(model.displayCount == model.rows.count + model.placeholderCount + model.groups.count)
        #expect(model.lastChange == .reload)
        for _ in 0..<20 { model.moveCursor(by: 1) }
        let cursor = try #require(model.cursor)
        let shown = try #require(model.displayIndex(of: cursor))
        #expect(model.rowIndex(atDisplay: shown) == model.cursorIndex)
        for header in model.groups.headers {
            let display = model.groups.displayIndex(ofHeader: model.groups.headers.firstIndex(of: header)!)
            #expect(model.rowIndex(atDisplay: display) == nil && model.header(atDisplay: display) == header)
            #expect(model.rowIndex(atOrAfterDisplay: display) == header.row)
        }
        let snoozed = ThreadListModel(data: store, location: .system(.snoozed), account: AccountID(1), now: { fixedNow })
        snoozed.groupsByDate = true
        #expect(snoozed.groups.isEmpty)

        model.groupsByDate = false
        #expect(model.groups.isEmpty && model.displayCount == model.rows.count + model.placeholderCount)
    }
}
