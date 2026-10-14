import Foundation

public struct EmailEventFacts: Sendable, Hashable {
    public var start: Date
    public var end: Date?
    public var hasTime: Bool
    public var zoneAbbreviation: String?
    public var location: String
    public var strongSignal: Bool
    public var provenance: String
}

public enum EmailEventExtractor {
    public static func extract(texts: [String], htmls: [String], timeZone: TimeZone, now: Date) -> EmailEventFacts? {
        let ordered = texts.isEmpty ? [] : Array(texts.dropFirst().reversed()) + [texts[0]]
        for html in htmls.reversed() {
            if var facts = jsonLDEvent(in: html, timeZone: timeZone) {
                facts.strongSignal = true
                facts.provenance = provenance(facts, timeZone: timeZone, now: now, source: .markup)
                return facts
            }
        }
        for text in ordered where text.contains("BEGIN:VEVENT") {
            if var facts = icsEvent(in: text, timeZone: timeZone) {
                facts.strongSignal = true
                facts.provenance = provenance(facts, timeZone: timeZone, now: now, source: .markup)
                return facts
            }
        }
        var past: Found?
        for text in ordered {
            guard let found = wordsEvent(in: withoutQuotedHistory(text), timeZone: timeZone, now: now) else { continue }
            if found.facts.start >= now { return finished(found, timeZone: timeZone, now: now) }
            if past == nil { past = found }
        }
        return past.map { finished($0, timeZone: timeZone, now: now) }
    }

    private static func finished(_ found: Found, timeZone: TimeZone, now: Date) -> EmailEventFacts {
        var facts = found.facts
        facts.provenance = provenance(facts, timeZone: timeZone, now: now, source: .words,
                                      weekdayMismatch: found.weekdayMismatch)
        return facts
    }

    private static let attribution = regex(
        "(?:^|\\s)(?:On|Am|Le|El|Il|Op|Den|Em)\\s[^\\n]{1,250}?(?:\\n[^\\n]{0,120}?)?"
            + "(?:wrote|schrieb|a écrit|escribió|ha scritto|schreef|skrev|escreveu)\\s?:", ignoreCase: false)

    static func withoutQuotedHistory(_ text: String) -> String {
        guard let match = attribution.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        return String(text[..<range.lowerBound])
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let monthPattern = "(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
    private static let weekdayPattern = "(Sun(?:day)?|Mon(?:day)?|Tue(?:s(?:day)?)?|Wed(?:nesday)?|Thu(?:r(?:s(?:day)?)?)?|Fri(?:day)?|Sat(?:urday)?)"
    private static let zonePattern = "(PST|PDT|PT|MST|MDT|MT|CST|CDT|CT|EST|EDT|ET|UTC|GMT)"

    private static let namedDate = regex("(?:\\b\(weekdayPattern)\\.?,?\\s+)?\\b\(monthPattern)\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b(?:,?\\s+(\\d{4})\\b)?")
    private static let slashDate = regex("(?:\\b\(weekdayPattern)\\.?,?\\s+)?\\b(\\d{1,2})/(\\d{1,2})(?:/(\\d{2,4}))?\\b")
    private static let isoDate = regex("\\b(\\d{4})-(\\d{2})-(\\d{2})\\b")
    private static let timeRange = regex("\\b(\\d{1,2})(?::(\\d{2}))?\\s*([ap]\\.?m\\.?)?\\s*(?:-|–|—|to|until)\\s*(\\d{1,2})(?::(\\d{2}))?\\s*([ap]\\.?m\\.?)(?![a-z])")
    private static let singleTime = regex("\\b(\\d{1,2})(?::(\\d{2}))?\\s*([ap]\\.?m\\.?)(?![a-z])")
    private static let clock24 = regex("\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b(?!\\s*[ap]\\.?m)")
    private static let zoneAfter = regex("^\\s*\\(?\(zonePattern)\\b")
    private static let addToCalendar = regex("add\\s+to\\s+(?:my\\s+|your\\s+)?(?:google\\s+|apple\\s+|outlook\\s+)?calendar", ignoreCase: true)

    private static func regex(_ pattern: String, ignoreCase: Bool = true) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private struct DateHit {
        var month: Int
        var day: Int
        var year: Int?
        var weekday: Int?
        var range: NSRange
    }

    private struct Found {
        var facts: EmailEventFacts
        var weekdayMismatch: Bool
    }

    private static func wordsEvent(in text: String, timeZone: TimeZone, now: Date) -> Found? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let strong = addToCalendar.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        var past: Found?
        for (index, line) in lines.enumerated() {
            guard let hit = dateHit(in: line) else { continue }
            var window = Array(lines[index..<min(index + 3, lines.count)])
            window[0] = blanking(hit.range, in: line)
            guard let timed = timeHit(in: window) else { continue }
            let zone = timed.zone.flatMap(zone(forAbbreviation:)) ?? timeZone
            guard let day = resolve(hit, in: zone, now: now),
                  let start = zone.calendarDate(of: day.date, minutes: timed.start) else { continue }
            let end = timed.end.flatMap { zone.calendarDate(of: day.date, minutes: $0) }
            let found = Found(facts: EmailEventFacts(start: start, end: end, hasTime: true, zoneAbbreviation: timed.zone,
                                                     location: location(in: lines, around: index), strongSignal: strong,
                                                     provenance: ""),
                              weekdayMismatch: !day.weekdayMatches)
            if start >= now { return found }
            if past == nil { past = found }
        }
        return past
    }

    private static func blanking(_ range: NSRange, in line: String) -> String {
        let ns = line as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return line }
        return ns.replacingCharacters(in: range, with: String(repeating: " ", count: range.length))
    }

    private static func dateHit(in line: String) -> DateHit? {
        let range = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : Range(r, in: line).map { String(line[$0]) }
        }
        func weekday(_ name: String?) -> Int? {
            guard let key = name?.lowercased().prefix(3) else { return nil }
            return weekdayNames.firstIndex(of: String(key)).map { $0 + 1 }
        }
        if let m = isoDate.firstMatch(in: line, range: range), let y = Int(group(m, 1) ?? ""),
           let mo = Int(group(m, 2) ?? ""), let d = Int(group(m, 3) ?? ""), (1...12).contains(mo), (1...31).contains(d) {
            return DateHit(month: mo, day: d, year: y, weekday: nil, range: m.range)
        }
        if let m = namedDate.firstMatch(in: line, range: range), let name = group(m, 2),
           let mo = monthNames.firstIndex(of: String(name.lowercased().prefix(3))), let d = Int(group(m, 3) ?? ""),
           (1...31).contains(d) {
            return DateHit(month: mo + 1, day: d, year: Int(group(m, 4) ?? ""), weekday: weekday(group(m, 1)), range: m.range)
        }
        if let m = slashDate.firstMatch(in: line, range: range), let mo = Int(group(m, 2) ?? ""),
           let d = Int(group(m, 3) ?? ""), (1...12).contains(mo), (1...31).contains(d) {
            var year = Int(group(m, 4) ?? "")
            if let short = year, short < 100 { year = 2000 + short }
            return DateHit(month: mo, day: d, year: year, weekday: weekday(group(m, 1)), range: m.range)
        }
        return nil
    }

    private static func resolve(_ hit: DateHit, in zone: TimeZone, now: Date) -> (date: Date, weekdayMatches: Bool)? {
        let calendar = CalendarDateMentions.calendar(zone)
        func date(_ year: Int) -> Date? {
            let parts = DateComponents(year: year, month: hit.month, day: hit.day)
            guard let made = calendar.date(from: parts), calendar.component(.month, from: made) == hit.month,
                  calendar.component(.day, from: made) == hit.day else { return nil }
            return made
        }
        func matches(_ day: Date) -> Bool { hit.weekday.map { calendar.component(.weekday, from: day) == $0 } ?? true }
        if let year = hit.year { return date(year).map { ($0, matches($0)) } }
        let today = calendar.startOfDay(for: now)
        let first = calendar.component(.year, from: now)
        let ahead = (first...(first + 1)).compactMap(date).filter { $0 >= today }
        if let day = ahead.first(where: matches) { return (day, true) }
        guard let next = ahead.first ?? (first...(first + 8)).lazy.compactMap(date).first(where: { $0 >= today }) else {
            return nil
        }
        return (next, matches(next))
    }

    private struct TimeHit {
        var start: Int
        var end: Int?
        var zone: String?
    }

    private static func timeHit(in window: [String]) -> TimeHit? {
        for line in window {
            let range = NSRange(line.startIndex..., in: line)
            func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Range(r, in: line).map { String(line[$0]) }
            }
            func minutes(_ hour: String?, _ minute: String?, _ meridiem: String?) -> Int? {
                guard var h = Int(hour ?? ""), (0...23).contains(h) else { return nil }
                let m = Int(minute ?? "0") ?? 0
                if let mer = meridiem?.lowercased().first {
                    guard (1...12).contains(h) else { return nil }
                    h = h % 12 + (mer == "p" ? 12 : 0)
                }
                return h * 60 + m
            }
            func zone(after match: NSTextCheckingResult) -> String? {
                let tail = String(line[Range(match.range, in: line)!.upperBound...])
                guard let z = zoneAfter.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                      let r = Range(z.range(at: 1), in: tail) else { return nil }
                return String(tail[r]).uppercased()
            }
            if let m = timeRange.firstMatch(in: line, range: range) {
                let endMeridiem = group(m, 6)
                if let end = minutes(group(m, 4), group(m, 5), endMeridiem),
                   let start = minutes(group(m, 1), group(m, 2), group(m, 3) ?? endMeridiem) {
                    return TimeHit(start: start, end: end > start ? end : nil, zone: zone(after: m))
                }
            }
            if let m = singleTime.firstMatch(in: line, range: range),
               let start = minutes(group(m, 1), group(m, 2), group(m, 3)) {
                return TimeHit(start: start, end: nil, zone: zone(after: m))
            }
            if let m = clock24.firstMatch(in: line, range: range), let start = minutes(group(m, 1), group(m, 2), nil) {
                return TimeHit(start: start, end: nil, zone: zone(after: m))
            }
        }
        return nil
    }

    static func zone(forAbbreviation abbreviation: String) -> TimeZone? {
        switch abbreviation.uppercased() {
        case "PT": return TimeZone(identifier: "America/Los_Angeles")
        case "MT": return TimeZone(identifier: "America/Denver")
        case "CT": return TimeZone(identifier: "America/Chicago")
        case "ET": return TimeZone(identifier: "America/New_York")
        case "UTC", "GMT": return TimeZone(secondsFromGMT: 0)
        case let other: return TimeZone(abbreviation: other)
        }
    }

    private static let streetLine = regex("^\\d{1,6}\\s+[A-Za-z0-9 .'#-]+?\\b(?:St|Street|Ave|Avenue|Blvd|Boulevard|Rd|Road|Dr|Drive|Ln|Lane|Way|Pl|Place|Ct|Court|Pkwy|Parkway|Hwy|Highway|Sq|Square|Ter|Terrace)\\b\\.?(?:,?\\s*(?:Suite|Ste|Apt|Unit|Floor|Fl)\\.?\\s*\\w+)?,?$")
    private static let cityLine = regex("^[A-Za-z][A-Za-z .'-]*,\\s*[A-Z]{2}\\s+\\d{5}(?:-\\d{4})?$", ignoreCase: false)
    private static let oneLineAddress = regex("^\\d{1,6}\\s+.+,\\s*[A-Za-z][A-Za-z .'-]*,\\s*[A-Z]{2}\\s+\\d{5}(?:-\\d{4})?$", ignoreCase: false)
    private static let labelled = regex("^(?:location|where|venue|address)\\s*[:\\-]\\s*(.+)$")
    private static let labelAlone = regex("^(?:location|where|venue|address)\\s*:?$")
    private static let notVenue = regex("add\\s+to\\s+calendar|view\\s+map|guest\\s+list|rsvp|view\\s+guest|get\\s+directions|^\\W*$")

    private static func matches(_ re: NSRegularExpression, _ line: String) -> Bool {
        re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func location(in lines: [String], around dateIndex: Int) -> String {
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let m = labelled.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) {
                return String(line[r]).trimmingCharacters(in: .whitespaces)
            }
            if matches(labelAlone, line) {
                let next = lines[(i + 1)...].prefix(3).filter { !$0.isEmpty }
                if !next.isEmpty { return next.joined(separator: ", ") }
            }
        }
        for (i, line) in lines.enumerated() {
            if matches(oneLineAddress, line) { return venue(before: i, in: lines).map { "\($0), \(line)" } ?? line }
            guard matches(streetLine, line) else { continue }
            var parts = [line.trimmingCharacters(in: CharacterSet(charactersIn: ", "))]
            if i + 1 < lines.count, matches(cityLine, lines[i + 1]) { parts.append(lines[i + 1]) }
            if let name = venue(before: i, in: lines) { parts.insert(name, at: 0) }
            return parts.joined(separator: ", ")
        }
        return ""
    }

    private static func venue(before index: Int, in lines: [String]) -> String? {
        guard index > 0 else { return nil }
        let line = lines[index - 1]
        guard !line.isEmpty, line.count <= 80, !matches(notVenue, line), dateHit(in: line) == nil,
              timeHit(in: [line]) == nil else { return nil }
        return line
    }

    private static func jsonLDEvent(in html: String, timeZone: TimeZone) -> EmailEventFacts? {
        let scripts = regex("<script[^>]*ld\\+json[^>]*>(.*?)</script>", ignoreCase: true)
        let whole = NSRange(html.startIndex..., in: html)
        let dotAll = (try? NSRegularExpression(pattern: scripts.pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
            ?? scripts
        for match in dotAll.matches(in: html, range: whole) {
            guard let r = Range(match.range(at: 1), in: html), let data = String(html[r]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data), let event = findEvent(json) else { continue }
            guard let startText = event["startDate"] as? String, let (start, hasTime) = parseISO(startText, timeZone) else {
                continue
            }
            let end = (event["endDate"] as? String).flatMap { parseISO($0, timeZone)?.0 }
            return EmailEventFacts(start: start, end: end, hasTime: hasTime, zoneAbbreviation: nil,
                                   location: locationText(event["location"]), strongSignal: true, provenance: "")
        }
        return nil
    }

    private static func findEvent(_ node: Any) -> [String: Any]? {
        if let list = node as? [Any] { return list.lazy.compactMap { findEvent($0) }.first }
        guard let dict = node as? [String: Any] else { return nil }
        let types = (dict["@type"] as? String).map { [$0] } ?? (dict["@type"] as? [String]) ?? []
        if types.contains(where: { $0.hasSuffix("Event") }) { return dict }
        return findEvent(dict["@graph"] as Any)
    }

    private static func locationText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [Any], let first = list.first { return locationText(first) }
        guard let dict = value as? [String: Any] else { return "" }
        var parts: [String] = []
        if let name = dict["name"] as? String { parts.append(name) }
        if let address = dict["address"] as? String {
            parts.append(address)
        } else if let address = dict["address"] as? [String: Any] {
            let street = address["streetAddress"] as? String
            let place = [address["addressLocality"], address["addressRegion"]].compactMap { $0 as? String }
                .joined(separator: ", ")
            let postal = address["postalCode"] as? String
            parts += [street, [place, postal].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")]
                .compactMap { $0 }.filter { !$0.isEmpty }
        }
        return parts.joined(separator: ", ")
    }

    private static func parseISO(_ text: String, _ zone: TimeZone) -> (Date, Bool)? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return (date, true) }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        for (format, timed) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd", false)] {
            local.dateFormat = format
            if let date = local.date(from: text) { return (date, timed) }
        }
        return nil
    }

    private static func icsEvent(in text: String, timeZone: TimeZone) -> EmailEventFacts? {
        guard let begin = text.range(of: "BEGIN:VEVENT") else { return nil }
        let body = text[begin.upperBound...].replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        var start: Date?, end: Date?, hasTime = true, place = ""
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("END:VEVENT") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]).uppercased(), value = String(line[line.index(after: colon)...])
            let name = head.split(separator: ";").first.map(String.init) ?? head
            switch name {
            case "DTSTART", "DTEND":
                var zone = timeZone
                if let tz = head.range(of: "TZID=").map({ String(head[$0.upperBound...].split(separator: ";").first ?? "") }),
                   let named = TimeZone(identifier: tz) ?? TimeZone(identifier: tz.capitalized) { zone = named }
                guard let parsed = parseICS(value, zone) else { continue }
                if name == "DTSTART" { start = parsed.0; hasTime = parsed.1 } else { end = parsed.0 }
            case "LOCATION":
                place = value.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\n", with: ", ")
                    .replacingOccurrences(of: "\\;", with: ";")
            default: break
            }
        }
        guard let start else { return nil }
        return EmailEventFacts(start: start, end: end, hasTime: hasTime, zoneAbbreviation: nil, location: place,
                               strongSignal: true, provenance: "")
    }

    private static func parseICS(_ value: String, _ zone: TimeZone) -> (Date, Bool)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return formatter.date(from: text).map { ($0, true) }
        }
        formatter.timeZone = zone
        for (format, timed) in [("yyyyMMdd'T'HHmmss", true), ("yyyyMMdd", false)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return (date, timed) }
        }
        return nil
    }

    private enum Source { case words, markup }

    private static func provenance(_ facts: EmailEventFacts, timeZone: TimeZone, now: Date, source: Source,
                                   weekdayMismatch: Bool = false) -> String {
        let prefix = source == .words ? String(localized: "From the email:") : String(localized: "From the email's event details:")
        let abbreviation = facts.zoneAbbreviation
        let writtenZone = abbreviation.flatMap { zone(forAbbreviation: $0) } ?? timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = writtenZone
        let calendar = CalendarDateMentions.calendar(writtenZone)
        let year = calendar.component(.year, from: facts.start) != calendar.component(.year, from: now) ? " y" : ""
        formatter.setLocalizedDateFormatFromTemplate(facts.hasTime ? "EEE MMM d\(year) h:mm a" : "EEE MMM d\(year)")
        var text = "\(prefix) \(formatter.string(from: facts.start))"
        if let abbreviation { text += " \(abbreviation)" }
        if facts.hasTime, writtenZone.secondsFromGMT(for: facts.start) != timeZone.secondsFromGMT(for: facts.start) {
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("h:mm a")
            text += " = \(formatter.string(from: facts.start)) \(timeZone.localizedName(for: .shortStandard, locale: Locale(identifier: "en_US")) ?? timeZone.identifier)"
        }
        if weekdayMismatch { text += " " + String(localized: "(the weekday in the email does not match)") }
        return text
    }
}

private extension TimeZone {
    func calendarDate(of day: Date, minutes: Int) -> Date? {
        CalendarDateMentions.calendar(self).date(byAdding: .minute, value: minutes, to: day)
    }
}
