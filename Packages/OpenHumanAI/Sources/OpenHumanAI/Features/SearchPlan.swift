import Foundation

public struct SearchPlan: Sendable, Hashable, Codable {
    public enum Timeframe: String, Sendable, Codable, CaseIterable {
        case none, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear
        case pastDays, pastWeeks, pastMonths, pastYears
        case month, year, sinceMonth, beforeMonth

        public var needsCount: Bool { [Timeframe.pastDays, .pastWeeks, .pastMonths, .pastYears].contains(self) }
    }

    public enum AttachmentType: String, Sendable, Codable, CaseIterable {
        case any, pdf, document, spreadsheet, presentation, image, calendar
    }

    public enum Mailbox: String, Sendable, Codable, CaseIterable {
        case any, inbox, sent, drafts, anywhere
    }

    public var keywords: [String]
    public var from: [String]
    public var to: [String]
    public var timeframe: Timeframe
    public var count: Int?
    public var month: Int?
    public var year: Int?
    public var attachment: AttachmentType?
    public var unread: Bool?
    public var starred: Bool?
    public var mailbox: Mailbox
    public var label: String?
    public var topic: String?

    public init(keywords: [String] = [], from: [String] = [], to: [String] = [], timeframe: Timeframe = .none,
                count: Int? = nil, month: Int? = nil, year: Int? = nil, attachment: AttachmentType? = nil,
                unread: Bool? = nil, starred: Bool? = nil, mailbox: Mailbox = .any, label: String? = nil,
                topic: String? = nil) {
        self.keywords = keywords
        self.from = from
        self.to = to
        self.timeframe = timeframe
        self.count = count
        self.month = month
        self.year = year
        self.attachment = attachment
        self.unread = unread
        self.starred = starred
        self.mailbox = mailbox
        self.label = label
        self.topic = topic
    }

    private enum CodingKeys: String, CodingKey {
        case keywords, from, to, timeframe, count, month, year, attachment, unread, starred, mailbox, label, topic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        from = try c.decodeIfPresent([String].self, forKey: .from) ?? []
        to = try c.decodeIfPresent([String].self, forKey: .to) ?? []
        timeframe = try c.decodeIfPresent(Timeframe.self, forKey: .timeframe) ?? .none
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        month = try c.decodeIfPresent(Int.self, forKey: .month)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        attachment = try c.decodeIfPresent(AttachmentType.self, forKey: .attachment)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred)
        mailbox = try c.decodeIfPresent(Mailbox.self, forKey: .mailbox) ?? .any
        label = try c.decodeIfPresent(String.self, forKey: .label)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
    }

    public var isEmpty: Bool {
        keywords.isEmpty && from.isEmpty && to.isEmpty && timeframe == .none && attachment == nil && unread != true
            && starred != true && mailbox == .any && (label ?? "").isEmpty
    }
}

public struct SearchPlanResult: Sendable, Hashable {
    public var plan: SearchPlan
    public var provenance: AIProvenance
    public var report: AIOutputReport

    public init(plan: SearchPlan, provenance: AIProvenance, report: AIOutputReport) {
        self.plan = plan
        self.provenance = provenance
        self.report = report
    }
}

extension OutputGuard {
    public static let searchPlanSchema: JSONSchema = .object(
        properties: [
            "keywords": .array(items: .string(maxLength: AIPolicy.searchPlanKeywordCharacters),
                               maxItems: AIPolicy.searchPlanMaxKeywords),
            "from": .array(items: .string(maxLength: 100), maxItems: AIPolicy.searchPlanMaxPeople),
            "to": .array(items: .string(maxLength: 100), maxItems: AIPolicy.searchPlanMaxPeople),
            "timeframe": .string(enumValues: SearchPlan.Timeframe.allCases.map(\.rawValue)),
            "count": .integer(minimum: 1, maximum: 36),
            "month": .integer(minimum: 1, maximum: 12),
            "year": .integer(minimum: 2000, maximum: 2100),
            "attachment": .string(enumValues: SearchPlan.AttachmentType.allCases.map(\.rawValue)),
            "unread": .boolean,
            "starred": .boolean,
            "mailbox": .string(enumValues: SearchPlan.Mailbox.allCases.map(\.rawValue)),
            "label": .string(maxLength: 60),
            "topic": .string(maxLength: 200),
        ],
        required: ["keywords", "timeframe", "mailbox"])

    public static func searchPlan(from data: Data) throws -> SearchPlan {
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw AIError.invalidOutput("not JSON")
        }
        guard case .object(var fields) = parsed else { throw AIError.invalidOutput("not an object") }
        fields = fields.filter { $0.value != .null }
        let value = JSONValue.object(fields)
        let errors = searchPlanSchema.validate(value)
        guard errors.isEmpty else { throw AIError.invalidOutput(errors.prefix(3).joined(separator: "; ")) }
        var plan: SearchPlan
        do {
            plan = try JSONDecoder().decode(SearchPlan.self, from: Data(value.canonicalString.utf8))
        } catch {
            throw AIError.invalidOutput("search plan fields")
        }
        if plan.timeframe.needsCount, plan.count == nil { throw AIError.invalidOutput("timeframe needs a count") }
        if [SearchPlan.Timeframe.month, .sinceMonth, .beforeMonth].contains(plan.timeframe), plan.month == nil {
            throw AIError.invalidOutput("timeframe needs a month")
        }
        if plan.timeframe == .year, plan.year == nil { throw AIError.invalidOutput("timeframe needs a year") }
        func clean(_ words: [String]) -> [String] {
            words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        plan.keywords = clean(plan.keywords)
        plan.from = clean(plan.from)
        plan.to = clean(plan.to)
        plan.label = plan.label.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        plan.topic = plan.topic.map {
            $0.split(whereSeparator: \.isWhitespace).prefix(AIPolicy.searchPlanTopicWords).joined(separator: " ")
        }.flatMap { $0.isEmpty ? nil : $0 }
        return plan
    }
}
