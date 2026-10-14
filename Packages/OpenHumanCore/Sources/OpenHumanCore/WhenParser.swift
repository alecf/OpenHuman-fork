import Foundation

public enum WhenParserError: Error, Equatable, Sendable {
    case empty
    case unrecognized(String)
}

public struct WhenParser: Sendable {
    public var timeZone: TimeZone
    public var defaultHour: Int
    public var eveningHour: Int

    public init(timeZone: TimeZone = .current, defaultHour: Int = 8, eveningHour: Int = 20) {
        self.timeZone = timeZone
        self.defaultHour = defaultHour
        self.eveningHour = eveningHour
    }

    public static func isLaterTodayPhrase(_ input: String) -> Bool {
        ["later today", "later", "later on", "today later"].contains(normalized(input))
    }

    private static func normalized(_ input: String) -> String {
        var words = input.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first == "at" || first == "on" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    public func laterToday(now: Date) -> (date: Date, isEvening: Bool)? {
        let cal = calendar
        if cal.component(.hour, from: now) < 18 {
            return (roundedUpToTheHour(now.addingTimeInterval(3 * 3600)), false)
        }
        if cal.component(.hour, from: now) < eveningHour,
           let evening = try? at(cal.startOfDay(for: now), eveningHour, 0, "evening") { return (evening, true) }
        return nil
    }

    public func tonight(now: Date) -> Date? {
        let cal = calendar
        if cal.component(.hour, from: now) < eveningHour,
           let evening = try? at(cal.startOfDay(for: now), eveningHour, 0, "tonight") { return evening }
        guard cal.component(.hour, from: now) < 22 else { return nil }
        let next = roundedUpToTheHour(now.addingTimeInterval(3600))
        return cal.isDate(next, inSameDayAs: now) ? next : nil
    }

    private func roundedUpToTheHour(_ date: Date) -> Date {
        let cal = calendar
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let exact = (c.minute ?? 0) == 0 && (c.second ?? 0) == 0
        c.minute = 0; c.second = 0
        return cal.date(from: c).map { exact ? $0 : $0.addingTimeInterval(3600) } ?? date
    }

    private func tomorrowMorning(now: Date) throws -> Date {
        let cal = calendar
        guard let day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else {
            throw WhenParserError.unrecognized("tomorrow")
        }
        return try at(day, defaultHour, 0, "tomorrow")
    }

    private func parseClockPhrase(_ text: String, now: Date) throws -> Date? {
        let cal = calendar
        let hour = cal.component(.hour, from: now)
        switch text {
        case "later today", "later", "later on", "today later":
            return try laterToday(now: now)?.date ?? tomorrowMorning(now: now)
        case "tonight", "this evening", "this night":
            return try tonight(now: now) ?? tomorrowMorning(now: now)
        case "this afternoon":
            if hour < 13 { return try at(cal.startOfDay(for: now), 13, 0, text) }
            if hour < 17 { return roundedUpToTheHour(now.addingTimeInterval(3600)) }
            return try laterToday(now: now)?.date ?? tomorrowMorning(now: now)
        default:
            return nil
        }
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        return c
    }

    public func parse(_ input: String, now: Date, relativeToNow: Bool = true) throws -> Date {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WhenParserError.empty }
        if let iso = parseISO(raw) { return iso }

        var words = raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first == "at" || first == "on" { words.removeFirst() }
        let text = words.joined(separator: " ")
        guard !words.isEmpty else { throw WhenParserError.unrecognized(input) }

        if text == "now" { return now }
        if words.count >= 2, let moved = Self.dayPhraseLast(words) {
            return try parse(moved, now: now, relativeToNow: relativeToNow)
        }
        if relativeToNow, let phrase = try parseClockPhrase(text, now: now) { return phrase }
        if let rel = parseRelative(text, now: now) { return rel }

        var day: Date?
        let isTonight = words.first == "tonight"
        var defaultTime = (hour: defaultHour, minute: 0)
        var rest = words
        let cal = calendar
        let today = cal.startOfDay(for: now)
        func consume(_ n: Int) { rest.removeFirst(n) }

        if rest.first == "today" {
            day = today; defaultTime = (18, 0); consume(1)
        } else if rest.first == "tonight" {
            day = today; defaultTime = (20, 0); consume(1)
        } else if rest.first == "tomorrow" || rest.first == "tmrw" {
            day = cal.date(byAdding: .day, value: 1, to: today); consume(1)
        } else if rest.count >= 2, rest[0] == "next", rest[1] == "week" {
            day = nextWeekday(2, after: today); consume(2)
        } else if rest.first == "weekend" {
            day = nextWeekday(7, after: today, allowToday: false); consume(1)
        } else if rest.count >= 2, rest[0] == "this", rest[1] == "weekend" {
            day = nextWeekday(7, after: today, allowToday: false); consume(2)
        } else {
            var offset = 0
            if let f = rest.first, f == "next" || f == "this" { offset = 1 }
            if rest.count > offset, let wd = Self.weekday(rest[offset]) {
                day = nextWeekday(wd, after: today); consume(offset + 1)
            } else if let (md, used) = monthDay(rest, today: today) {
                day = md; consume(used)
            }
        }

        var time: (hour: Int, minute: Int)?
        while let f = rest.first, f == "at" { rest.removeFirst() }
        if !rest.isEmpty {
            let timeText = rest.joined(separator: " ")
            if let t = Self.parseTime(timeText, defaultHour: defaultHour) {
                time = t
            } else if day != nil, let t = Self.bareHour(timeText) {
                time = (isTonight && t.hour >= 1 && t.hour <= 11) ? (t.hour + 12, t.minute) : t
            } else {
                throw WhenParserError.unrecognized(input)
            }
        }

        switch (day, time) {
        case let (d?, t):
            let tt = t ?? defaultTime
            return try at(d, tt.hour, tt.minute, input)
        case let (nil, t?):
            let candidate = try at(today, t.hour, t.minute, input)
            if candidate > now { return candidate }
            guard let tomorrow = cal.date(byAdding: .day, value: 1, to: today) else { throw WhenParserError.unrecognized(input) }
            return try at(tomorrow, t.hour, t.minute, input)
        case (nil, nil):
            throw WhenParserError.unrecognized(input)
        }
    }

    private func at(_ day: Date, _ hour: Int, _ minute: Int, _ input: String) throws -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: day)
        c.hour = hour
        c.minute = minute
        c.second = 0
        guard let d = resolveLocal(c) else { throw WhenParserError.unrecognized(input) }
        return d
    }

    func resolveLocal(_ c: DateComponents) -> Date? {
        let cal = calendar
        guard let candidate = cal.date(from: c) else { return nil }
        let wanted: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        func matches(_ d: Date) -> Bool {
            let got = cal.dateComponents(wanted, from: d)
            return got.year == c.year && got.month == c.month && got.day == c.day
                && got.hour == (c.hour ?? 0) && got.minute == (c.minute ?? 0)
        }
        if matches(candidate) {
            for shift in [3600.0, 1800.0] where matches(candidate.addingTimeInterval(-shift)) {
                return candidate.addingTimeInterval(-shift)
            }
            return candidate
        }
        var dayStart = c
        dayStart.hour = 0; dayStart.minute = 0; dayStart.second = 0
        if let start = cal.date(from: dayStart),
           let transition = timeZone.nextDaylightSavingTimeTransition(after: start),
           cal.isDate(transition, inSameDayAs: start) {
            return transition
        }
        return candidate
    }

    private func nextWeekday(_ weekday: Int, after day: Date, allowToday: Bool = false) -> Date? {
        let cal = calendar
        let current = cal.component(.weekday, from: day)
        var delta = (weekday - current + 7) % 7
        if delta == 0 && !allowToday { delta = 7 }
        return cal.date(byAdding: .day, value: delta, to: day)
    }

    private func monthDay(_ words: [String], today: Date) -> (Date, Int)? {
        guard words.count >= 2 else { return nil }
        let month: Int, dayNumber: Int
        if let m = Self.month(words[0]), let d = Self.dayOfMonth(words[1]) {
            month = m; dayNumber = d
        } else if let d = Self.dayOfMonth(words[0]), let m = Self.month(words[1]) {
            month = m; dayNumber = d
        } else {
            return nil
        }
        var used = 2
        let cal = calendar
        var year = cal.component(.year, from: today)
        var explicitYear = false
        if words.count > 2, words[2].count == 4, words[2].allSatisfy({ $0.isASCII && $0.isNumber }), let y = Int(words[2]) {
            year = y; used = 3; explicitYear = true
        }
        func startOfDay(_ y: Int) -> Date? {
            guard let d = cal.date(from: DateComponents(year: y, month: month, day: dayNumber, hour: 12)),
                  cal.component(.day, from: d) == dayNumber, cal.component(.month, from: d) == month else { return nil }
            return cal.startOfDay(for: d)
        }
        for candidate in year..<(year + (explicitYear ? 1 : 9)) {
            if let date = startOfDay(candidate), explicitYear || date >= today { return (date, used) }
        }
        return nil
    }

    private static func month(_ word: String) -> Int? {
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                     "october", "november", "december"]
        let w = word.hasSuffix(".") ? String(word.dropLast()) : word
        if w == "sept" { return 9 }
        for (i, name) in names.enumerated() where w == name || (w.count == 3 && name.hasPrefix(w)) { return i + 1 }
        return nil
    }

    private static func dayOfMonth(_ word: String) -> Int? {
        var w = Substring(word)
        for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) { w = w.dropLast(2); break }
        guard (1...2).contains(w.count), w.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(w),
              (1...31).contains(n) else { return nil }
        return n
    }

    static func bareHour(_ text: String) -> (hour: Int, minute: Int)? {
        guard (1...2).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }), let h = Int(text) else { return nil }
        switch h {
        case 1...6: return (h + 12, 0)
        case 7...12: return (h, 0)
        case 0, 13...23: return (h, 0)
        default: return nil
        }
    }

    private static func weekday(_ word: String) -> Int? {
        let names: [(String, Int)] = [("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
                                      ("thursday", 5), ("friday", 6), ("saturday", 7)]
        for (name, n) in names {
            if word == name || (word.count >= 3 && name.hasPrefix(word) && word.count <= name.count) { return n }
        }
        if word == "tues" { return 3 }
        if word == "thur" || word == "thurs" { return 5 }
        return nil
    }

    private func parseRelative(_ text: String, now: Date) -> Date? {
        var body: Substring
        if text.hasPrefix("+") { body = text.dropFirst() } else if text.hasPrefix("in ") { body = text.dropFirst(3) } else { return nil }
        body = body.drop { $0 == " " }
        if text.hasPrefix("in "), let word = Self.wordRelative(String(body)) {
            switch word.unit {
            case .minutes: return now.addingTimeInterval(TimeInterval(word.count * 60))
            case .hours: return now.addingTimeInterval(TimeInterval(word.count * 3600))
            case .days: return calendar.date(byAdding: .day, value: word.count, to: now)
            case .weeks: return calendar.date(byAdding: .day, value: 7 * word.count, to: now)
            }
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard let n = Int(digits), n >= 0, n <= 100_000 else { return nil }
        let unit = body.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let seconds: Int
        switch unit {
        case "m", "min", "mins", "minute", "minutes": seconds = 60
        case "h", "hr", "hrs", "hour", "hours": seconds = 3600
        case "d", "day", "days": return calendar.date(byAdding: .day, value: n, to: now)
        case "w", "wk", "wks", "week", "weeks": return calendar.date(byAdding: .day, value: 7 * n, to: now)
        default: return nil
        }
        return now.addingTimeInterval(TimeInterval(n * seconds))
    }

    private static func dayPhraseLast(_ words: [String]) -> String? {
        guard let last = words.last else { return nil }
        let dayWords: Set<String> = ["today", "tonight", "tomorrow", "tmrw"]
        guard dayWords.contains(last) || weekday(last) != nil else { return nil }
        let head = Array(words.dropLast())
        guard let first = head.first, !dayWords.contains(first), weekday(first) == nil, month(first) == nil,
              first != "next", first != "this", first != "in", first != "+", !first.hasPrefix("+") else { return nil }
        let timeText = head.filter { $0 != "at" }.joined(separator: " ")
        guard parseTime(timeText, defaultHour: 8) != nil || (head.first == "at" && bareHour(timeText) != nil) else { return nil }
        return ([last] + head).joined(separator: " ")
    }

    private enum RelativeUnit { case minutes, hours, days, weeks }

    private static func wordRelative(_ body: String) -> (count: Int, unit: RelativeUnit)? {
        switch body {
        case "a minute", "one minute": return (1, .minutes)
        case "half an hour", "half hour", "30 minutes": return (30, .minutes)
        case "an hour", "one hour", "a hour": return (1, .hours)
        case "a couple of hours", "a couple hours", "couple of hours", "a couple of hrs": return (2, .hours)
        case "a few hours": return (3, .hours)
        case "a day", "one day": return (1, .days)
        case "a couple of days", "a couple days": return (2, .days)
        case "a few days": return (3, .days)
        case "a week", "one week": return (1, .weeks)
        default: return nil
        }
    }

    static func parseTime(_ text: String, defaultHour: Int) -> (hour: Int, minute: Int)? {
        switch text {
        case "noon": return (12, 0)
        case "midnight": return (0, 0)
        case "morning": return (defaultHour, 0)
        case "afternoon": return (13, 0)
        case "evening": return (18, 0)
        default: break
        }
        var t = text.replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where t.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1))
            t = String(t.dropLast(suffix.count))
            break
        }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              var hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0...59).contains(minute) else { return nil }
        if parts.count == 2, parts[1].count != 2 { return nil }
        if let m = meridiem {
            guard (1...12).contains(hour) else { return nil }
            if m == "a" { hour = hour == 12 ? 0 : hour } else { hour = hour == 12 ? 12 : hour + 12 }
        } else {
            guard parts.count == 2, (0...23).contains(hour) else { return nil }
        }
        return (hour, minute)
    }

    private func parseISO(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: text) { return d }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: text) { return d }

        let chars = Array(text)
        guard chars.count >= 10, chars[4] == "-", chars[7] == "-",
              let y = Int(String(chars[0..<4])), let mo = Int(String(chars[5..<7])), let d = Int(String(chars[8..<10]))
        else { return nil }
        var c = DateComponents(year: y, month: mo, day: d, hour: defaultHour, minute: 0, second: 0)
        if chars.count > 10 {
            guard chars[10] == "T" || chars[10] == " " else { return nil }
            let timeText = String(chars[11...])
            let tp = timeText.split(separator: ":")
            guard tp.count == 2 || tp.count == 3, tp.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
                  let h = Int(tp[0]), let mi = Int(tp[1]), (0...23).contains(h), (0...59).contains(mi)
            else { return nil }
            c.hour = h; c.minute = mi
            c.second = tp.count == 3 ? Int(tp[2]) : 0
        }
        guard (1...12).contains(mo), (1...31).contains(d), let date = resolveLocal(c),
              calendar.component(.day, from: date) == d else { return nil }
        return date
    }
}
