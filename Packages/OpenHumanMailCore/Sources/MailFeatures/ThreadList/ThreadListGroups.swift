import Foundation
import MailModel

public enum ThreadDateGroup: Hashable, Sendable {
    case today, yesterday, lastSevenDays, thisMonth
    case month(year: Int, month: Int)
}

extension ThreadRowFormatting {
    public func dateGroup(_ date: Date, now: Date) -> ThreadDateGroup {
        for group in [ThreadDateGroup.today, .yesterday, .lastSevenDays] {
            if let start = groupStart(group, now: now), date >= start { return group }
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let current = calendar.dateComponents([.year, .month], from: now)
        if parts.year == current.year, parts.month == current.month { return .thisMonth }
        return .month(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    public func groupStart(_ group: ThreadDateGroup, now: Date) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch group {
        case .today: return today
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)
        case .lastSevenDays: return calendar.date(byAdding: .day, value: -6, to: today)
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)?.start
        case .month(let year, let month): return calendar.date(from: DateComponents(year: year, month: month, day: 1))
        }
    }

    public func groupTitle(_ group: ThreadDateGroup, now: Date) -> String {
        switch group {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .lastSevenDays: return String(localized: "Last 7 days")
        case .thisMonth: return String(localized: "This month")
        case .month(let year, let month):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 15)) else { return "" }
            var style = year == calendar.component(.year, from: now)
                ? Date.FormatStyle().month(.wide) : Date.FormatStyle().month(.wide).year()
            style.calendar = calendar
            style.locale = locale
            style.timeZone = calendar.timeZone
            return date.formatted(style)
        }
    }
}

public struct ThreadListGroups: Sendable, Equatable {
    public struct Header: Sendable, Equatable {
        public let group: ThreadDateGroup
        public let title: String
        public let row: Int

        public init(group: ThreadDateGroup, title: String, row: Int) {
            self.group = group
            self.title = title
            self.row = row
        }
    }

    public enum Item: Sendable, Equatable {
        case row(Int)
        case header(Int)
    }

    public let headers: [Header]

    public init(headers: [Header] = []) {
        self.headers = headers
    }

    public static let none = ThreadListGroups()

    public static func applies(groupsByDate: Bool, sortsAscending: Bool, searchOrdering: SearchResultsOrdering?) -> Bool {
        groupsByDate && !sortsAscending && searchOrdering != .relevance
    }

    public var count: Int { headers.count }
    public var isEmpty: Bool { headers.isEmpty }

    public static func make(rows: [ThreadRow], format: ThreadRowFormatting, now: Date,
                            date: (ThreadRow) -> Date = { $0.sortAt }) -> ThreadListGroups {
        var headers: [Header] = []
        var seen = Set<ThreadDateGroup>()
        var i = 0
        while i < rows.count {
            let group = format.dateGroup(date(rows[i]), now: now)
            if group != .today, seen.insert(group).inserted {
                headers.append(Header(group: group, title: format.groupTitle(group, now: now), row: i))
            }
            guard let start = format.groupStart(group, now: now) else { break }
            var low = i + 1, high = rows.count
            while low < high {
                let mid = (low + high) / 2
                if date(rows[mid]) >= start { low = mid + 1 } else { high = mid }
            }
            i = low
        }
        return ThreadListGroups(headers: headers)
    }

    public func displayCount(rows rowCount: Int) -> Int { rowCount + headers.count }

    public func displayIndex(ofRow row: Int) -> Int {
        var low = 0, high = headers.count
        while low < high {
            let mid = (low + high) / 2
            if headers[mid].row <= row { low = mid + 1 } else { high = mid }
        }
        return row + low
    }

    public func displayIndex(ofHeader index: Int) -> Int { headers[index].row + index }

    public func item(atDisplay display: Int) -> Item {
        var low = 0, high = headers.count
        while low < high {
            let mid = (low + high) / 2
            let shown = headers[mid].row + mid
            if shown == display { return .header(mid) }
            if shown < display { low = mid + 1 } else { high = mid }
        }
        return .row(display - low)
    }

    public func rowIndex(atOrAfterDisplay display: Int) -> Int {
        switch item(atDisplay: display) {
        case .row(let row): row
        case .header(let index): headers[index].row
        }
    }

    public static func translate(_ change: ThreadListChange, from old: ThreadListGroups,
                                 to new: ThreadListGroups) -> ThreadListChange {
        guard case .update(let edit) = change else { return .reload }
        if old.isEmpty, new.isEmpty { return change }
        var removed = IndexSet(), inserted = IndexSet(), reconfigured = IndexSet()
        for row in edit.removed { removed.insert(old.displayIndex(ofRow: row)) }
        for row in edit.inserted { inserted.insert(new.displayIndex(ofRow: row)) }
        for row in edit.reconfigured { reconfigured.insert(new.displayIndex(ofRow: row)) }
        var kept = Set<Int>()
        for (index, header) in old.headers.enumerated() {
            if let match = new.headers.firstIndex(where: { $0.group == header.group }),
               header.row - edit.removed.count(in: 0..<header.row)
                == new.headers[match].row - edit.inserted.count(in: 0..<new.headers[match].row) {
                kept.insert(match)
                if new.headers[match].title != header.title { reconfigured.insert(new.displayIndex(ofHeader: match)) }
            } else {
                removed.insert(old.displayIndex(ofHeader: index))
            }
        }
        for index in new.headers.indices where !kept.contains(index) { inserted.insert(new.displayIndex(ofHeader: index)) }
        guard removed.count + inserted.count <= ThreadListEdit.maximumIncremental else { return .reload }
        return .update(ThreadListEdit(removed: removed, inserted: inserted, reconfigured: reconfigured))
    }
}
