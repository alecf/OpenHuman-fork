import Foundation
import OpenHumanCore

public struct SchedulingProposal: Sendable, Hashable {
    public enum Precision: String, Sendable, Hashable {
        case time
        case window
        case day
    }

    public var start: Date
    public var end: Date
    public var precision: Precision
    public var timeZone: TimeZone
    public var zoneStated: Bool
    public var fromModel: Bool

    public init(start: Date, end: Date, precision: Precision, timeZone: TimeZone, zoneStated: Bool = false,
                fromModel: Bool = false) {
        self.start = start
        self.end = end
        self.precision = precision
        self.timeZone = timeZone
        self.zoneStated = zoneStated
        self.fromModel = fromModel
    }

    public var length: TimeInterval { end.timeIntervalSince(start) }
}

public enum SchedulingProposalParser {
    public static let defaultLength: TimeInterval = 30 * 60
    public static let maxProposals = 6

    static let zoneWords: [String: String] = [
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "pacific": "America/Los_Angeles",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver", "mountain time": "America/Denver",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago", "central time": "America/Chicago",
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York", "eastern": "America/New_York",
        "gmt": "GMT", "utc": "UTC", "bst": "Europe/London", "uk time": "Europe/London",
        "cet": "Europe/Paris", "cest": "Europe/Paris", "jst": "Asia/Tokyo", "aest": "Australia/Sydney",
        "aedt": "Australia/Sydney",
    ]

    // Fail closed: read a sentence for times only if it asks or proposes, not merely names a day
    static let cues = ["how about", "what about", "can we", "could we", "shall we", "should we", "let's", "lets meet",
                       "lets talk", "are you free", "are you around", "are you available", "would you be free",
                       "would you be available", "is there a time", "find a time", "propose", "works for you",
                       "work for you", "works for me", "works for us", "would work", "could work", "does that work",
                       "free to meet", "free for a", "available for a", "i'm free", "i am free", "i'm available",
                       "i am available", "my availability", "your availability", "schedule a", "schedule time",
                       "book a", "reschedule", "move our", "push our"]

    static let questionCues = ["meet", "call", "chat", "sync", "catch up", "talk", "work", "free", "available", "time",
                               "slot", "instead", "join"]

    static let timeReference = #"\b(today|tonight|tomorrow|mon|monday|tue|tues|tuesday|wed|wednesday|thu|thur|thurs|thursday|fri|friday|sat|saturday|sun|sunday|week|weekend|month|january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec|morning|afternoon|evening|noon|lunch|lunchtime|eod|\d{1,2}(:\d{2})?\s*(am|pm)?)\b"#

    static let partsOfDay: [String: ((Int, Int), (Int, Int))] = [
        "morning": ((9, 0), (12, 0)), "lunch": ((12, 0), (13, 30)), "lunchtime": ((12, 0), (13, 30)),
        "afternoon": ((13, 0), (17, 0)), "evening": ((17, 0), (19, 0)), "end of day": ((16, 0), (18, 0)),
        "eod": ((16, 0), (18, 0)),
    ]

    public static func find(in text: String, sentAt: Date, authorZone: TimeZone, now: Date,
                            workday: Range<Int> = 9..<18) -> [SchedulingProposal] {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let messageZones = Set(zones(in: normalized).map(\.1))
        let messageZone = messageZones.count == 1 ? messageZones.first.flatMap(TimeZone.init(identifier:)) : nil
        var out: [SchedulingProposal] = []
        for sentence in sentences(normalized) where isScheduling(sentence) {
            let stated = zones(in: sentence).first.flatMap { TimeZone(identifier: $0.1) }
            let zone = stated ?? messageZone ?? authorZone
            let zoneStated = stated != nil || messageZone != nil
            out += proposals(in: sentence, sentAt: sentAt, zone: zone, zoneStated: zoneStated, workday: workday)
        }
        var seen = Set<String>()
        let kept = out.filter { $0.end > now }.sorted { $0.start < $1.start }.filter {
            seen.insert("\($0.start.timeIntervalSince1970)-\($0.end.timeIntervalSince1970)").inserted
        }
        return Array(kept.prefix(maxProposals))
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "?" || character == "!" || character == "\n" || character == ";" {
                out.append(current)
                current = ""
            } else if character == "." {
                let before = current.dropLast()
                let word = before.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
                let abbreviation = before.last?.isLetter == true && abbreviations.contains(word)
                if !(before.last?.isNumber ?? false), !abbreviation {
                    out.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static let abbreviations: Set<String> = ["jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov",
                                             "dec", "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun"]

    static func bareHour(_ hour: Int) -> (Int, Int)? {
        switch hour {
        case 1...6: (hour + 12, 0)
        case 7...12, 0, 13...23: (hour, 0)
        default: nil
        }
    }

    static func isScheduling(_ sentence: String) -> Bool {
        cues.contains { sentence.contains($0) } || sentence.contains("?") && questionCues.contains { sentence.contains($0) }
    }

    static func asksAboutTime(_ text: String) -> Bool {
        sentences(text.lowercased()).contains { sentence in
            isScheduling(sentence) && !matches(timeReference, in: sentence).isEmpty
        }
    }

    static func zones(in text: String) -> [(Int, String)] {
        let pattern = #"\b(pt|pst|pdt|mt|mst|mdt|ct|cst|cdt|et|est|edt|gmt|utc|bst|cet|cest|jst|aest|aedt|pacific|eastern|mountain time|central time|uk time)\b"#
        return matches(pattern, in: text).compactMap { match in
            guard let word = match.groups[1], let id = zoneWords[word] else { return nil }
            return (match.offset, id)
        }
    }

    private static func proposals(in sentence: String, sentAt: Date, zone: TimeZone, zoneStated: Bool,
                                  workday: Range<Int>) -> [SchedulingProposal] {
        let parser = WhenParser(timeZone: zone, defaultHour: workday.lowerBound)
        let calendar = CalendarDateMentions.calendar(zone)
        var masked = sentence
        let days = dayMentions(in: sentence, parser: parser, sentAt: sentAt, calendar: calendar)
        var times: [(offset: Int, start: (Int, Int), end: (Int, Int)?)] = []
        let range = #"(?:from\s+|between\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|to|until|till|and)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        for match in matches(range, in: masked) {
            guard let end = clock(match.groups[4], match.groups[5], match.groups[6]) else { continue }
            let startMeridiem = match.groups[3] ?? inferMeridiem(start: match.groups[1], end: end)
            guard let start = clock(match.groups[1], match.groups[2], startMeridiem) else { continue }
            times.append((match.offset, start, end))
            masked = mask(masked, match.range)
        }
        let single = #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b|\bat\s+(\d{1,2})\b(?!\s*(?:%|people|minutes|mins|hours))"#
        for match in matches(single, in: masked) {
            var time: (Int, Int)?
            if match.groups[1] != nil {
                time = clock(match.groups[1], match.groups[2], match.groups[3])
            } else if let hour = match.groups[4].flatMap(Int.init), let minute = match.groups[5].flatMap(Int.init),
                      (0...23).contains(hour), (0...59).contains(minute) {
                time = (hour, minute)
            } else if let bare = match.groups[6].flatMap(Int.init) {
                time = bareHour(bare)
            }
            if let time { times.append((match.offset, time, nil)) }
            masked = mask(masked, match.range)
        }
        if let noon = matches(#"\bnoon\b"#, in: masked).first { times.append((noon.offset, (12, 0), nil)) }
        for (word, window) in partsOfDay {
            for match in matches("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", in: masked) {
                times.append((match.offset, window.0, window.1))
            }
        }
        var out: [SchedulingProposal] = []
        if times.isEmpty {
            for day in days {
                let lastDay = day.isWeek ? calendar.date(byAdding: .day, value: 4, to: day.start) ?? day.start : day.start
                guard let start = calendar.date(bySettingHour: workday.lowerBound, minute: 0, second: 0, of: day.start),
                      let end = calendar.date(bySettingHour: workday.upperBound, minute: 0, second: 0, of: lastDay)
                else { continue }
                out.append(SchedulingProposal(start: start, end: end, precision: .day, timeZone: zone,
                                              zoneStated: zoneStated))
            }
            return out
        }
        for time in times.sorted(by: { $0.offset < $1.offset }) {
            let day = nearest(days, to: time.offset)?.start
                ?? timeAloneDay(time.start, sentAt: sentAt, calendar: calendar)
            guard let start = calendar.date(bySettingHour: time.start.0, minute: time.start.1, second: 0, of: day)
            else { continue }
            if let endClock = time.end, let end = calendar.date(bySettingHour: endClock.0, minute: endClock.1, second: 0, of: day),
               end > start {
                out.append(SchedulingProposal(start: start, end: end, precision: .window, timeZone: zone,
                                              zoneStated: zoneStated))
            } else {
                out.append(SchedulingProposal(start: start, end: start.addingTimeInterval(defaultLength),
                                              precision: .time, timeZone: zone, zoneStated: zoneStated))
            }
        }
        return out
    }

    struct DayMention {
        let offset: Int
        let start: Date
        let isWeek: Bool
    }

    static func dayMentions(in sentence: String, parser: WhenParser, sentAt: Date, calendar: Calendar) -> [DayMention] {
        let pattern = #"\b(today|tonight|tomorrow|tmrw|next week|(?:(?:this|next)\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|wed|thurs|thur|thu|fri|sat|sun)|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?)\b"#
        return matches(pattern, in: sentence).compactMap { match in
            guard let words = match.groups[1] else { return nil }
            let cleaned = words.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: #"(\d)(st|nd|rd|th)"#, with: "$1", options: .regularExpression)
            guard let date = try? parser.parse(cleaned, now: sentAt) else { return nil }
            return DayMention(offset: match.offset, start: calendar.startOfDay(for: date), isWeek: words == "next week")
        }
    }

    private static func nearest(_ days: [DayMention], to offset: Int) -> DayMention? {
        days.min { abs($0.offset - offset) < abs($1.offset - offset) }
    }

    private static func timeAloneDay(_ time: (Int, Int), sentAt: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: sentAt)
        if let candidate = calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day), candidate > sentAt {
            return day
        }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }

    static func clock(_ hour: String?, _ minute: String?, _ meridiem: String?) -> (Int, Int)? {
        guard let hourText = hour, var h = Int(hourText) else { return nil }
        let m = minute.flatMap(Int.init) ?? 0
        guard (0...59).contains(m) else { return nil }
        switch meridiem {
        case "am"?:
            guard (1...12).contains(h) else { return nil }
            h = h == 12 ? 0 : h
        case "pm"?:
            guard (1...12).contains(h) else { return nil }
            h = h == 12 ? 12 : h + 12
        default:
            guard (0...23).contains(h) else { return nil }
        }
        return (h, m)
    }

    static func inferMeridiem(start: String?, end: (Int, Int)) -> String {
        guard let hour = start.flatMap(Int.init), (1...12).contains(hour) else { return "am" }
        let asPM = hour == 12 ? 12 : hour + 12
        return asPM < end.0 || (asPM == end.0 && end.1 > 0) ? "pm" : "am"
    }

    struct Match {
        let offset: Int
        let range: NSRange
        let groups: [String?]
    }

    static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
            let groups = (0..<result.numberOfRanges).map { index -> String? in
                let range = result.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            return Match(offset: result.range.location, range: result.range, groups: groups)
        }
    }

    static func mask(_ text: String, _ range: NSRange) -> String {
        (text as NSString).replacingCharacters(in: range, with: String(repeating: " ", count: range.length))
    }
}
