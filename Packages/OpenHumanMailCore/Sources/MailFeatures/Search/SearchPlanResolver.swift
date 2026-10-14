import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct ResolvedSearchPlan: Sendable, Hashable {
    public enum ChipKind: Sendable, Hashable { case topic, person, dates, attribute, label, mailbox, note }

    public struct Chip: Sendable, Hashable {
        public var kind: ChipKind
        public var title: String

        public init(kind: ChipKind, title: String) {
            self.kind = kind
            self.title = title
        }
    }

    public var canonicalText: String
    public var chips: [Chip]
    public var semanticText: String?
    public var spokenSummary: String

    public init(canonicalText: String, chips: [Chip], semanticText: String? = nil, spokenSummary: String) {
        self.canonicalText = canonicalText
        self.chips = chips
        self.semanticText = semanticText
        self.spokenSummary = spokenSummary
    }
}

public struct SearchPlanResolver: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var isValidQuery: @Sendable (String) -> Bool

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
                isValidQuery: @escaping @Sendable (String) -> Bool = SearchPlanResolver.syntaxIsValid) {
        self.calendar = calendar
        self.locale = locale
        self.isValidQuery = isValidQuery
    }

    public func resolve(_ plan: SearchPlan, account: AccountID, today: Date,
                        contacts: (String) async -> [EmailAddress], labels: [LabelInfo]) async -> ResolvedSearchPlan? {
        var terms: [String] = []
        var chips: [ResolvedSearchPlan.Chip] = []
        var spoken: [String] = []

        for keyword in plan.keywords.prefix(AIPolicy.searchPlanMaxKeywords) {
            let word = Self.oneLine(keyword)
            guard !word.isEmpty else { continue }
            terms.append(Self.quoted(word))
            chips.append(.init(kind: .topic, title: word))
            spoken.append(word)
        }
        for (field, people) in [("from", plan.from), ("to", plan.to)] {
            for person in people.prefix(AIPolicy.searchPlanMaxPeople) {
                let written = Self.oneLine(person)
                guard !written.isEmpty else { continue }
                let (value, title) = await resolvePerson(written, contacts: contacts)
                terms.append("\(field):" + Self.quoted(value))
                chips.append(.init(kind: .person, title: "\(field) \(title)"))
                spoken.append("\(field) \(title)")
            }
        }
        if let range = dateRange(plan, today: today) {
            if let after = range.after { terms.append("after:" + Self.queryDate(after, calendar: calendar)) }
            if let before = range.before { terms.append("before:" + Self.queryDate(before, calendar: calendar)) }
            chips.append(.init(kind: .dates, title: rangeTitle(range, today: today, wide: false)))
            spoken.append(rangeTitle(range, today: today, wide: true))
        }
        if let attachment = plan.attachment {
            terms.append(Self.attachmentQuery(attachment))
            let title = Self.attachmentTitle(attachment)
            chips.append(.init(kind: .attribute, title: title))
            spoken.append(title)
        }
        if plan.unread == true {
            terms.append("is:unread")
            chips.append(.init(kind: .attribute, title: "unread"))
            spoken.append("unread")
        }
        if plan.starred == true {
            terms.append("is:starred")
            chips.append(.init(kind: .attribute, title: "starred"))
            spoken.append("starred")
        }
        if let mailbox = Self.mailbox(plan.mailbox) {
            terms.append(mailbox.query)
            chips.append(.init(kind: .mailbox, title: mailbox.title))
            spoken.append(mailbox.title)
        }
        if let written = plan.label.map(Self.oneLine), !written.isEmpty {
            if let label = Self.matchLabel(written, in: labels) {
                terms.append("label:" + Self.quoted(label.name, always: true))
                chips.append(.init(kind: .label, title: label.displayName))
                spoken.append("label \(label.displayName)")
            } else {
                chips.append(.init(kind: .note, title: "No label named \(written)"))
            }
        }
        let canonical = terms.joined(separator: " ")
        guard !canonical.isEmpty, isValidQuery(canonical) else { return nil }
        let summary = "Suggested search: " + spoken.joined(separator: ", ") + ". Press Tab to use."
        return ResolvedSearchPlan(canonicalText: canonical, chips: chips, semanticText: plan.topic, spokenSummary: summary)
    }

    func resolvePerson(_ written: String, contacts: (String) async -> [EmailAddress]) async -> (value: String, title: String) {
        if written.contains("@") { return (written.lowercased(), written) }
        let matches = await contacts(written).filter { contact in
            guard let name = contact.name else { return false }
            return name.range(of: written, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        var unique: [String: EmailAddress] = [:]
        for contact in matches { unique[contact.email.lowercased()] = unique[contact.email.lowercased()] ?? contact }
        switch unique.count {
        case 1:
            let contact = unique.values.first!
            return (contact.email, contact.name ?? contact.email)
        case 0:
            return (written, written)
        default:
            return (written, "\(written) (\(unique.count) people)")
        }
    }

    struct DateRange: Hashable {
        var after: Date?
        var before: Date?
    }

    func dateRange(_ plan: SearchPlan, today: Date) -> DateRange? {
        let day = calendar.startOfDay(for: today)
        func add(_ component: Calendar.Component, _ value: Int, to date: Date) -> Date {
            calendar.date(byAdding: component, value: value, to: date) ?? date
        }
        func startOfMonth(_ year: Int, _ month: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: 1))
        }
        let currentYear = calendar.component(.year, from: day)
        let currentMonth = calendar.component(.month, from: day)
        func monthStart(_ month: Int?, year: Int?) -> Date? {
            guard let month else { return nil }
            if let year { return startOfMonth(year, month) }
            return startOfMonth(month <= currentMonth ? currentYear : currentYear - 1, month)
        }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day

        switch plan.timeframe {
        case .none:
            return nil
        case .today:
            return DateRange(after: day, before: nil)
        case .yesterday:
            return DateRange(after: add(.day, -1, to: day), before: day)
        case .thisWeek:
            return DateRange(after: weekStart, before: nil)
        case .lastWeek:
            return DateRange(after: add(.day, -7, to: weekStart), before: weekStart)
        case .thisMonth:
            return startOfMonth(currentYear, currentMonth).map { DateRange(after: $0, before: nil) }
        case .lastMonth:
            guard let start = startOfMonth(currentYear, currentMonth) else { return nil }
            return DateRange(after: add(.month, -1, to: start), before: start)
        case .thisYear:
            return startOfMonth(currentYear, 1).map { DateRange(after: $0, before: nil) }
        case .lastYear:
            guard let start = startOfMonth(currentYear, 1) else { return nil }
            return DateRange(after: add(.year, -1, to: start), before: start)
        case .pastDays, .pastWeeks, .pastMonths, .pastYears:
            guard let count = plan.count, count > 0 else { return nil }
            let component: Calendar.Component = switch plan.timeframe {
            case .pastDays: .day
            case .pastWeeks: .weekOfYear
            case .pastMonths: .month
            default: .year
            }
            return DateRange(after: add(component, -count, to: day), before: nil)
        case .month:
            guard let start = monthStart(plan.month, year: plan.year) else { return nil }
            return DateRange(after: start, before: add(.month, 1, to: start))
        case .year:
            guard let year = plan.year, let start = startOfMonth(year, 1) else { return nil }
            return DateRange(after: start, before: add(.year, 1, to: start))
        case .sinceMonth:
            return monthStart(plan.month, year: plan.year).map { DateRange(after: $0, before: nil) }
        case .beforeMonth:
            return monthStart(plan.month, year: plan.year).map { DateRange(after: nil, before: $0) }
        }
    }

    func rangeTitle(_ range: DateRange, today: Date, wide: Bool) -> String {
        let thisYear = calendar.component(.year, from: today)
        func format(_ date: Date) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone)
                .month(wide ? .wide : .abbreviated).day()
            if calendar.component(.year, from: date) != thisYear { style = style.year() }
            return date.formatted(style)
        }
        let lastDay = range.before.map { calendar.date(byAdding: .day, value: -1, to: $0) ?? $0 }
        switch (range.after, lastDay) {
        case let (after?, last?):
            return calendar.isDate(after, inSameDayAs: last) ? format(after) : "\(format(after)) to \(format(last))"
        case let (after?, nil):
            return calendar.isDate(after, inSameDayAs: today) ? "Today" : "Since \(format(after))"
        case let (nil, last?):
            return "Before \(format(calendar.date(byAdding: .day, value: 1, to: last) ?? last))"
        case (nil, nil):
            return ""
        }
    }

    static func queryDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    static func attachmentQuery(_ type: SearchPlan.AttachmentType) -> String {
        switch type {
        case .any: "has:attachment"
        case .pdf: "has:attachment filename:pdf"
        case .document: "has:attachment {filename:doc filename:docx}"
        case .spreadsheet: "has:attachment {filename:xls filename:xlsx filename:csv}"
        case .presentation: "has:attachment {filename:ppt filename:pptx filename:key}"
        case .image: "has:attachment {filename:png filename:jpg filename:jpeg filename:heic}"
        case .calendar: "has:invite"
        }
    }

    static func attachmentTitle(_ type: SearchPlan.AttachmentType) -> String {
        switch type {
        case .any: "with attachments"
        case .pdf: "PDFs"
        case .document: "documents"
        case .spreadsheet: "spreadsheets"
        case .presentation: "presentations"
        case .image: "images"
        case .calendar: "invitations"
        }
    }

    static func mailbox(_ mailbox: SearchPlan.Mailbox) -> (query: String, title: String)? {
        switch mailbox {
        case .any: nil
        case .inbox: ("in:inbox", "in Inbox")
        case .sent: ("in:sent", "in Sent")
        case .drafts: ("in:drafts", "in Drafts")
        case .anywhere: ("in:anywhere", "everywhere, Trash and Spam too")
        }
    }

    static func matchLabel(_ written: String, in labels: [LabelInfo]) -> LabelInfo? {
        let user = labels.filter { $0.kind == .user && !$0.isHidden }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let exact = user.first(where: {
            $0.name.compare(written, options: options) == .orderedSame
                || $0.displayName.compare(written, options: options) == .orderedSame
        }) { return exact }
        return user.first { $0.displayName.range(of: written, options: options.union(.anchored)) != nil }
            ?? user.first { $0.name.range(of: written, options: options.union(.anchored)) != nil }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" || $0 == "\"" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func quoted(_ value: String, always: Bool = false) -> String {
        always || value.contains(where: { $0.isWhitespace || "(){}:".contains($0) }) ? "\"\(value)\"" : value
    }

    public static let syntaxIsValid: @Sendable (String) -> Bool = { text in
        guard text.filter({ $0 == "\"" }).count % 2 == 0 else { return false }
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth < 0 { return false }
        }
        guard depth == 0 else { return false }
        return SearchSyntax.tokens(text).allSatisfy(\.isValid)
    }
}
