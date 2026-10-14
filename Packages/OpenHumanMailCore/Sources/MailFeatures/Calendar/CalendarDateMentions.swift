import Foundation

public struct CalendarDateMention: Sendable, Hashable {
    public let date: Date
    public let hasTime: Bool
    public let duration: TimeInterval?
    public let namedTimeZone: Bool

    public init(date: Date, hasTime: Bool, duration: TimeInterval? = nil, namedTimeZone: Bool = false) {
        self.date = date
        self.hasTime = hasTime
        self.duration = duration
        self.namedTimeZone = namedTimeZone
    }
}

public struct CalendarDateSpan: Sendable, Hashable {
    public let range: NSRange
    public let words: String
    public let mention: CalendarDateMention

    public init(range: NSRange, words: String, mention: CalendarDateMention) {
        self.range = range
        self.words = words
        self.mention = mention
    }
}

public enum CalendarDateMentions {
    public static let maxMentions = 50
    public static let maxDays = 5

    public static func find(in text: String, timeZone: TimeZone) -> [CalendarDateMention] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [CalendarDateMention] = []
        for match in detector.matches(in: text, options: [], range: range) {
            guard let detected = match.date, let words = Range(match.range, in: text).map({ String(text[$0]) }) else {
                continue
            }
            let named = match.timeZone != nil
            let date = named ? detected : rebuild(detected, from: .current, in: timeZone)
            let duration = match.duration > 0 ? match.duration : nil
            out.append(CalendarDateMention(date: date, hasTime: mentionsTime(words), duration: duration, namedTimeZone: named))
            if out.count >= maxMentions { break }
        }
        return out
    }

    public static func spans(in text: String, timeZone: TimeZone) -> [CalendarDateSpan] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        var out: [CalendarDateSpan] = []
        for match in detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)) {
            guard let detected = match.date, let range = Range(match.range, in: text) else { continue }
            let words = String(text[range])
            guard words.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { continue }
            let named = match.timeZone != nil
            let date = named ? detected : rebuild(detected, from: .current, in: timeZone)
            let mention = CalendarDateMention(date: date, hasTime: mentionsTime(words),
                                              duration: match.duration > 0 ? match.duration : nil, namedTimeZone: named)
            out.append(CalendarDateSpan(range: match.range, words: words, mention: mention))
            if out.count >= maxMentions { break }
        }
        return out
    }

    public static func span(at location: Int, in spans: [CalendarDateSpan]) -> CalendarDateSpan? {
        spans.first { location >= $0.range.location && location <= NSMaxRange($0.range) }
    }

    public static func days(_ mentions: [CalendarDateMention], timeZone: TimeZone, today: Date,
                            limit: Int = maxDays) -> [Date] {
        let calendar = Self.calendar(timeZone)
        let starts = Set(mentions.map { calendar.startOfDay(for: $0.date) }).sorted()
        let todayStart = calendar.startOfDay(for: today)
        let upcoming = starts.filter { $0 >= todayStart }
        let past = starts.filter { $0 < todayStart }.reversed()
        return Array((upcoming + past).prefix(limit)).sorted()
    }

    public static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func rebuild(_ date: Date, from source: TimeZone, in zone: TimeZone) -> Date {
        guard source.identifier != zone.identifier else { return date }
        let parts = calendar(source).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return calendar(zone).date(from: parts) ?? date
    }

    static func mentionsTime(_ words: String) -> Bool {
        words.range(of: #"(?i)\b\d{1,2}(:\d{2})?\s*([ap]\.?m\.?)(?![a-z])|\b\d{1,2}:\d{2}\b|\bnoon\b|\bmidnight\b"#,
                    options: .regularExpression) != nil
    }
}
