import Foundation
import MailModel
import OpenHumanCore

public struct ThreadRowChip: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case important
        case category
        case label
        case overflow
        case vip
    }

    public let kind: Kind
    public let title: String
    public let color: String?
    public let isFallback: Bool

    public init(kind: Kind, title: String, color: String? = nil, isFallback: Bool = false) {
        self.kind = kind
        self.title = title
        self.color = color
        self.isFallback = isFallback
    }
}

public struct ThreadRowChipContext: Sendable {
    public var location: MailLocation
    public var labels: [Int64: LabelInfo]
    public var impliesImportance: Bool
    public var superhuman: SuperhumanLabelRules

    public init(location: MailLocation, labels: [Int64: LabelInfo] = [:], impliesImportance: Bool = false,
                superhuman: SuperhumanLabelRules = SuperhumanLabelRules()) {
        self.location = location
        self.labels = labels
        self.impliesImportance = impliesImportance
        self.superhuman = superhuman
    }
}

public enum ThreadRowIndicator: String, Sendable, Hashable, CaseIterable {
    case muted
    case starred, reminder, snoozed, scheduled, draft, attachment, pending

    public var symbol: String {
        switch self {
        case .muted: "speaker.slash"
        case .starred: "star.fill"
        case .reminder: "bell"
        case .snoozed: "clock"
        case .scheduled: "calendar.badge.clock"
        case .draft: "pencil"
        case .attachment: "paperclip"
        case .pending: "arrow.triangle.2.circlepath"
        }
    }

    public var spoken: String {
        switch self {
        case .muted: String(localized: "muted")
        case .starred: String(localized: "starred")
        case .reminder: String(localized: "reminder set")
        case .snoozed: String(localized: "snoozed")
        case .scheduled: String(localized: "scheduled to send")
        case .draft: String(localized: "has draft")
        case .attachment: String(localized: "has attachment")
        case .pending: String(localized: "waiting to sync")
        }
    }
}

public struct ThreadRowFormatting: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public static let maximumLabelChips = 2
    public static let maximumIndicators = 2

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    public func listDate(_ date: Date, now: Date) -> String {
        let text = spokenListDate(date, now: now)
        guard !calendar.isDate(date, inSameDayAs: now), Self.isLatinScript(text) else { return text }
        return text.uppercased(with: locale)
    }

    public func spokenListDate(_ date: Date, now: Date) -> String {
        var style: Date.FormatStyle
        if calendar.isDate(date, inSameDayAs: now) {
            style = Date.FormatStyle(date: .omitted, time: .shortened)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = Date.FormatStyle().month(.abbreviated).day()
        } else {
            style = Date.FormatStyle().month(.abbreviated).day().year()
        }
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func isLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            guard scalar.properties.isAlphabetic else { return true }
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return true
            default: return false
            }
        }
    }

    public func upcomingDate(_ date: Date, now: Date) -> String {
        let text = spokenUpcomingDate(date, now: now)
        guard !calendar.isDate(date, inSameDayAs: now), Self.isLatinScript(text) else { return text }
        return text.uppercased(with: locale)
    }

    public func spokenUpcomingDate(_ date: Date, now: Date) -> String {
        var style: Date.FormatStyle
        if calendar.isDate(date, inSameDayAs: now) {
            style = Date.FormatStyle(date: .omitted, time: .shortened)
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                     to: calendar.startOfDay(for: date)).day, days > 0, days < 7 {
            style = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = Date.FormatStyle().month(.abbreviated).day()
        } else {
            style = Date.FormatStyle().month(.abbreviated).day().year()
        }
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    public func dateColumn(_ row: ThreadRow, location: MailLocation, now: Date) -> (text: String, isUpcoming: Bool) {
        let upcoming: Date? = switch location {
        case .system(.snoozed): row.snoozedUntil
        case .system(.reminders): row.reminderAt
        case .system(.scheduled): row.scheduledSendAt
        default: nil
        }
        if let upcoming, ReminderItem.isSomeday(upcoming) { return ("Someday", true) }
        if let upcoming { return (upcomingDate(upcoming, now: now), true) }
        return (listDate(row.lastMessageAt, now: now), false)
    }

    public func headerDate(_ date: Date, now: Date) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.locale = locale
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
            let ago = minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
            return "\(date.formatted(time)) (\(ago))"
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { day = day.year() }
        day.calendar = calendar
        day.locale = locale
        day.timeZone = calendar.timeZone
        return "\(date.formatted(day)), \(date.formatted(time))"
    }

    public func sender(_ row: ThreadRow) -> (name: String, count: String?) {
        var name = row.participantsDisplay.isEmpty ? (row.participants.first?.name ?? row.participants.first?.email ?? "") : row.participantsDisplay
        let count = row.messageCount > 1 ? "(\(row.messageCount))" : nil
        if let count, name.hasSuffix(" " + count) { name.removeLast(count.count + 1) }
        return (name, count)
    }

    public func showsDraftPrefix(_ row: ThreadRow, location: MailLocation) -> Bool {
        row.draftCount > 0 && (row.messageCount == 0 || location == .system(.drafts))
    }

    public func subject(_ row: ThreadRow) -> String? {
        let s = row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public func snippet(_ row: ThreadRow) -> String {
        guard row.snippet.contains(where: \.isNewline) else { return row.snippet }
        return row.snippet.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    public static func chips(for row: ThreadRow, context: ThreadRowChipContext,
                             autoLabel: String? = nil) -> [ThreadRowChip] {
        var chips: [ThreadRowChip] = []
        var currentLabel: GmailLabelID?
        if case .label(let id) = context.location { currentLabel = id }
        if row.isImportant, !context.impliesImportance {
            chips.append(ThreadRowChip(kind: .important, title: importantTitle))
        }
        let ours = autoLabel.flatMap { $0.isEmpty ? nil : $0 }
        let fallback = ours == nil ? superhumanCategory(of: row, context: context) : nil
        if let ours {
            chips.append(ThreadRowChip(kind: .category, title: ours))
        } else if let fallback {
            chips.append(ThreadRowChip(kind: .category, title: fallback, isFallback: true))
        }
        for id in row.categoryLabelIDs where ours == nil && fallback == nil {
            let label = context.labels[id]
            guard label?.labelID != currentLabel else { continue }
            guard let title = label.map(\.displayName) ?? nil, !title.isEmpty else { continue }
            chips.append(ThreadRowChip(kind: .category, title: title))
            break
        }
        let showsCategory = ours != nil || fallback != nil
        var userChips: [ThreadRowChip] = []
        for id in row.userLabelIDs {
            guard let label = context.labels[id], label.labelID != currentLabel, !label.isHidden,
                  !label.name.hasPrefix(OHGmailLabels.root + "/") else { continue }
            if context.superhuman.hides(label.name) { continue }
            if showsCategory, context.superhuman.category(forLabelName: label.name) != nil { continue }
            userChips.append(ThreadRowChip(kind: .label, title: label.displayName, color: label.colorBackground))
        }
        if userChips.count > maximumLabelChips {
            let extra = userChips.count - maximumLabelChips
            chips += userChips.prefix(maximumLabelChips)
            chips.append(ThreadRowChip(kind: .overflow, title: "+\(extra)"))
        } else {
            chips += userChips
        }
        return chips
    }

    private static let importantTitle = String(localized: "Important")

    static func superhumanCategory(of row: ThreadRow, context: ThreadRowChipContext) -> String? {
        let names = row.userLabelIDs.compactMap { context.labels[$0]?.name }
        return context.superhuman.category(inLabelNames: names)
    }

    public static func ruleImpliesImportance(_ rule: String) -> Bool {
        rule.trimmingCharacters(in: .whitespaces).lowercased() == "is:important"
    }

    public static func indicators(for row: ThreadRow, location: MailLocation, now: Date,
                                  muted: Bool = false) -> [ThreadRowIndicator] {
        var result: [ThreadRowIndicator] = []
        if muted { result.append(.muted) }
        if row.isStarred { result.append(.starred) }
        if row.reminderAt != nil, location != .system(.reminders) { result.append(.reminder) }
        if let until = row.snoozedUntil, until > now, location != .system(.snoozed) { result.append(.snoozed) }
        if row.snoozedUntil == nil, location == .system(.snoozed) { result.append(.snoozed) }
        if row.scheduledSendAt != nil, location != .system(.scheduled) { result.append(.scheduled) }
        if row.draftCount > 0 { result.append(.draft) }
        if row.attachmentCount > 0 { result.append(.attachment) }
        if row.hasPendingChanges { result.append(.pending) }
        return result
    }

    public func accessibilityLabel(_ row: ThreadRow, now: Date) -> String {
        accessibilityLabel(row, chips: [], location: .system(.inbox), now: now, includeSnippet: false)
    }

    public func accessibilityLabel(_ row: ThreadRow, chips: [ThreadRowChip], location: MailLocation, now: Date,
                                   includeSnippet: Bool = true, muted: Bool = false) -> String {
        var parts: [String] = []
        if row.isUnread { parts.append(String(localized: "Unread")) }
        if showsDraftPrefix(row, location: location) { parts.append(String(localized: "Draft")) }
        parts.append(sender(row).name)
        parts.append(subject(row) ?? String(localized: "No subject"))
        let date = dateColumn(row, location: location, now: now)
        parts.append(date.isUpcoming ? String(localized: "until \(spokenDate(row, location: location, now: now, column: date.text))")
                                     : spokenListDate(row.lastMessageAt, now: now))
        if row.attachmentCount > 0 { parts.append(ThreadRowIndicator.attachment.spoken) }
        for indicator in Self.indicators(for: row, location: location, now: now, muted: muted) where indicator != .attachment {
            parts.append(indicator.spoken)
        }
        for chip in chips {
            switch chip.kind {
            case .important: parts.append(String(localized: "important"))
            case .category:
                parts.append(chip.isFallback ? String(localized: "Superhuman category \(chip.title)")
                                             : String(localized: "category \(chip.title)"))
            case .label: parts.append(String(localized: "label \(chip.title)"))
            case .overflow: parts.append(String(localized: "\(chip.title) more labels"))
            case .vip: parts.append(String(localized: "from a VIP"))
            }
        }
        if includeSnippet {
            let text = snippet(row)
            if !text.isEmpty { parts.append(text) }
        }
        if row.searchMatch == .related { parts.append(SmartSearchStatusText.relatedSpoken) }
        return parts.joined(separator: ", ")
    }

    private func spokenDate(_ row: ThreadRow, location: MailLocation, now: Date, column: String) -> String {
        let upcoming: Date? = switch location {
        case .system(.snoozed): row.snoozedUntil
        case .system(.reminders): row.reminderAt
        case .system(.scheduled): row.scheduledSendAt
        default: nil
        }
        guard let upcoming, !ReminderItem.isSomeday(upcoming) else { return column }
        return spokenUpcomingDate(upcoming, now: now)
    }

    public func recipientsLine(_ message: MessageSummary, me: String) -> String {
        recipientsLine(message, me: [me.lowercased()])
    }

    public func recipientsLine(_ message: MessageSummary, me: Set<String>) -> String {
        let names = (message.to + message.cc).map { address -> String in
            if me.contains(address.email.lowercased()) { return "me" }
            return (address.name ?? address.email).split(separator: " ").first.map(String.init) ?? address.email
        }
        return names.isEmpty ? "" : "to " + names.joined(separator: ", ")
    }

    public func initials(name: String?, email: String) -> String {
        let source = (name?.isEmpty == false ? name! : email)
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
