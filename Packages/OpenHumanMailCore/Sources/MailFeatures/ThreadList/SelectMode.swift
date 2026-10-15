import Foundation
import MailActions
import MailModel
import Observation

public enum SelectionHeaderCheck: Equatable, Sendable {
    case hidden, some, all
}

public enum ListSidePanel: Equatable, Sendable {
    case recentOpens, shortcuts

    public static func state(checkedCount: Int) -> ListSidePanel { checkedCount > 0 ? .shortcuts : .recentOpens }

    public var title: String {
        switch self {
        case .recentOpens: "Recent Opens"
        case .shortcuts: "Shortcuts"
        }
    }
}

public enum SelectModeShortcuts {
    public struct Item: Equatable, Sendable, Identifiable {
        public let title: String
        public let keycaps: [String]
        public var id: String { title }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public let title: String
        public let items: [Item]
        public var id: String { title }
    }

    public static func sections(_ descriptors: [ActionDescriptor]) -> [Section] {
        func listScoped(_ d: ActionDescriptor) -> Bool { d.scopes.contains(.list) || d.scopes.contains(.global) }
        func caps(_ id: ActionID) -> [String]? {
            descriptors.first { $0.id == id }?.defaultBindings.first?.separatedKeycaps
        }
        func caps(key: String) -> [String]? {
            let chord = KeyBinding.Chord(.character(key))
            return descriptors.lazy.filter(listScoped)
                .compactMap { $0.defaultBindings.first { $0.chords == [chord] } }.first?.separatedKeycaps
        }
        func item(_ title: String, _ keycaps: [String]?) -> Item? { keycaps.map { Item(title: title, keycaps: $0) } }
        func titled(_ id: ActionID) -> Item? {
            guard let d = descriptors.first(where: { $0.id == id }) else { return nil }
            return item(headline(d.title), caps(id))
        }
        let navigation = [item("Next Conversation", caps(key: "j")), item("Previous Conversation", caps(key: "k")),
                          item("Select Conversation", caps(.toggleCheck))].compactMap { $0 }
        let selection = [item("Select All", caps(.checkAll)), item("Select All From Here", caps(.checkFromHere)),
                         item("Select Next", caps(.extendSelectionDown)), item("Select Previous", caps(.extendSelectionUp)),
                         item("Clear Selection", caps(.clearChecks))].compactMap { $0 }
        let actions = actionIDs.compactMap(titled)
        return [Section(title: "Navigation", items: navigation), Section(title: "Selection", items: selection),
                Section(title: "Actions", items: actions)].filter { !$0.items.isEmpty }
    }

    static let actionIDs: [ActionID] = [.markDone, .snooze, .remind, .label, .move, .toggleRead, .toggleStar, .trash, .spam]

    static func headline(_ title: String) -> String {
        let words = title.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).split(separator: " ")
        return words.enumerated().map { (index, word) -> String in
            index > 0 && minorWords.contains(word.lowercased()) ? word.lowercased() : word.prefix(1).uppercased() + String(word.dropFirst())
        }.joined(separator: " ")
    }

    static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to"]
}

@MainActor @Observable
public final class RecentOpens {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: ThreadKey
        public let sender: String
        public let subject: String
        public let openedAt: Date

        public init(id: ThreadKey, sender: String, subject: String, openedAt: Date) {
            self.id = id
            self.sender = sender
            self.subject = subject
            self.openedAt = openedAt
        }
    }

    public static let limit = 50
    public private(set) var entries: [Entry] = []

    public init() {}

    public func record(_ row: ThreadRow, at date: Date) {
        record(Entry(id: row.id, sender: ThreadRowFormatting().sender(row).name, subject: row.subject, openedAt: date))
    }

    public func record(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
}

public struct RecentOpenGroup: Equatable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable { case recent, yesterday, lastSevenDays, earlier }

    public struct Line: Equatable, Sendable, Identifiable {
        public let entry: RecentOpens.Entry
        public let stamp: String
        public var id: ThreadKey { entry.id }
    }

    public let kind: Kind
    public let lines: [Line]
    public var id: Kind { kind }

    public var title: String? {
        switch kind {
        case .recent: nil
        case .yesterday: "Yesterday"
        case .lastSevenDays: "Last 7 days"
        case .earlier: "Earlier"
        }
    }

    public static func groups(_ entries: [RecentOpens.Entry], now: Date, calendar: Calendar = .autoupdatingCurrent,
                              locale: Locale = .autoupdatingCurrent) -> [RecentOpenGroup] {
        let weekdayTime = formatter("EEEjmm", calendar: calendar, locale: locale)
        let monthDay = formatter("MMMd", calendar: calendar, locale: locale)
        let today = calendar.startOfDay(for: now)
        var buckets: [Kind: [Line]] = [:]
        for entry in entries.sorted(by: { $0.openedAt > $1.openedAt }) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.openedAt), to: today).day ?? 0
            let kind: Kind
            let stamp: String
            switch days {
            case ...0:
                kind = .recent
                stamp = relative(now.timeIntervalSince(entry.openedAt))
            case 1:
                kind = .yesterday
                stamp = weekdayTime.string(from: entry.openedAt)
            case 2...7:
                kind = .lastSevenDays
                stamp = weekdayTime.string(from: entry.openedAt)
            default:
                kind = .earlier
                stamp = monthDay.string(from: entry.openedAt)
            }
            buckets[kind, default: []].append(Line(entry: entry, stamp: stamp))
        }
        return [Kind.recent, .yesterday, .lastSevenDays, .earlier].compactMap { kind in
            buckets[kind].map { RecentOpenGroup(kind: kind, lines: $0) }
        }
    }

    static func relative(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        return hours == 1 ? "1 hr ago" : "\(hours) hrs ago"
    }

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
