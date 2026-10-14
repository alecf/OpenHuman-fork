import Foundation

public enum TokenHeuristic {
    public static let bytesPerToken = 3

    public static func count(_ text: String) -> Int {
        var tally = Tally()
        tally.add(text)
        return tally.tokens
    }

    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,
            0x2E80...0x2FDF,
            0x3000...0x303F,
            0x3040...0x30FF,
            0x3100...0x31FF,
            0x3200...0x33FF,
            0x3400...0x4DBF,
            0x4E00...0x9FFF,
            0xA960...0xA97F,
            0xAC00...0xD7FF,
            0xF900...0xFAFF,
            0xFF00...0xFFEF,
            0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    public struct Tally: Sendable, Hashable {
        public private(set) var cjkScalars = 0
        public private(set) var otherBytes = 0

        public init() {}

        public mutating func add(_ text: String) {
            for scalar in text.unicodeScalars {
                if TokenHeuristic.isCJK(scalar) {
                    cjkScalars += 1
                } else {
                    otherBytes += UTF8.width(scalar)
                }
            }
        }

        public var tokens: Int {
            cjkScalars + (otherBytes + TokenHeuristic.bytesPerToken - 1) / TokenHeuristic.bytesPerToken
        }
    }
}
