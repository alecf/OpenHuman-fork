import Foundation

public struct HLC: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let millis: Int64
    public let counter: UInt32
    public let device: String

    public init(millis: Int64, counter: UInt32, device: String) {
        self.millis = millis
        self.counter = counter
        self.device = device
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let millis = Int64(parts[0], radix: 16), millis >= 0,
              let counter = UInt32(parts[1], radix: 16), !parts[2].isEmpty else { return nil }
        self.init(millis: millis, counter: counter, device: String(parts[2]))
    }

    // Why: fixed-width hex keeps text order equal to clock order
    public var description: String {
        Self.hex(UInt64(millis), width: 12) + "." + Self.hex(UInt64(counter), width: 8) + "." + device
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        (lhs.millis, lhs.counter, lhs.device) < (rhs.millis, rhs.counter, rhs.device)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = HLC(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "malformed clock"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func hex(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

struct HLCClock {
    let device: String
    private(set) var last: HLC?

    init(device: String, last: HLC?) {
        self.device = device
        self.last = last
    }

    mutating func tick(now: Date) -> HLC {
        let physical = Self.millis(now)
        let next: HLC
        if let last, last.millis >= physical {
            next = last.counter == .max
                ? HLC(millis: last.millis + 1, counter: 0, device: device)
                : HLC(millis: last.millis, counter: last.counter + 1, device: device)
        } else {
            next = HLC(millis: physical, counter: 0, device: device)
        }
        last = next
        return next
    }

    mutating func observe(_ remote: HLC) {
        if let last, (remote.millis, remote.counter) <= (last.millis, last.counter) { return }
        last = HLC(millis: remote.millis, counter: remote.counter, device: device)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}
