import Foundation

public enum OHGmailLabels {
    public static let root = "OpenHuman"
    public static let agent = "OpenHuman/Agent"
    public static let snoozed = "OpenHuman/Snoozed"
    public static let scheduled = "OpenHuman/Scheduled"
    public static let sendAtHeader = "X-OpenHuman-Send-At"
    public static let sendAtConditionHeader = "X-OpenHuman-Send-At-Condition"
    public static let test = "OpenHuman/Test"
    public static let muted = "OpenHuman/Muted"
}

public struct SendAtCondition: Sendable, Hashable {
    public static let noReplyToken = "no-reply"

    public var anchor: GmailMessageID?

    public init(anchor: GmailMessageID?) {
        self.anchor = anchor
    }

    public var headerValue: String {
        guard let anchor, !anchor.rawValue.isEmpty else { return Self.noReplyToken }
        return Self.noReplyToken + " " + anchor.rawValue
    }

    public init?(headerValue: String) {
        let parts = headerValue.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first, first.lowercased() == Self.noReplyToken, parts.count <= 2 else { return nil }
        anchor = parts.count == 2 ? GmailMessageID(parts[1]) : nil
    }
}

public enum ScheduleStamp {
    public static let yearRange = 2000...9999

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    public static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    public static func format(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: floorToMinute(date))
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "T" + pad(c.hour, 2) + pad(c.minute, 2) + "Z"
    }

    public static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 14, b[8] == UInt8(ascii: "T"), b[13] == UInt8(ascii: "Z") else { return nil }
        func number(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                guard b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int(b[i] - UInt8(ascii: "0"))
            }
            return v
        }
        guard let y = number(0..<4), let mo = number(4..<6), let d = number(6..<8),
              let h = number(9..<11), let mi = number(11..<13),
              yearRange.contains(y), (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi),
              let date = utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
        else { return nil }
        return format(date) == text ? date : nil
    }
}

public struct ScheduleLabel: Hashable, Sendable, Comparable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case snoozed = "Snoozed"
        case scheduled = "Scheduled"

        fileprivate var order: Int { self == .snoozed ? 0 : 1 }
    }

    public enum ParseResult: Equatable, Sendable {
        case schedule(ScheduleLabel)
        case marker(Kind)
        case malformed(Kind)
        case notOurs
    }

    public static let prefix = "OpenHuman/"

    public let kind: Kind
    public let due: Date

    public init(kind: Kind, due: Date) {
        self.kind = kind
        self.due = ScheduleStamp.floorToMinute(due)
    }

    public var name: String { Self.markerName(kind) + "/" + ScheduleStamp.format(due) }

    public static func markerName(_ kind: Kind) -> String { prefix + kind.rawValue }

    public static func parse(_ name: String) -> ParseResult {
        for kind in Kind.allCases {
            let marker = markerName(kind)
            if name == marker { return .marker(kind) }
            guard name.hasPrefix(marker + "/") else { continue }
            guard let due = ScheduleStamp.parse(String(name.dropFirst(marker.count + 1))) else { return .malformed(kind) }
            return .schedule(ScheduleLabel(kind: kind, due: due))
        }
        return .notOurs
    }

    public static func < (lhs: ScheduleLabel, rhs: ScheduleLabel) -> Bool {
        (lhs.due, lhs.kind.order) < (rhs.due, rhs.kind.order)
    }

    public static func schedules(_ kind: Kind, in names: some Sequence<String>) -> [ScheduleLabel] {
        names.compactMap { name -> ScheduleLabel? in
            if case let .schedule(label) = parse(name), label.kind == kind { return label }
            return nil
        }.sorted()
    }
}
