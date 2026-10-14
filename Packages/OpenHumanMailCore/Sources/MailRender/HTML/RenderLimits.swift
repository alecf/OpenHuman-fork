import Foundation

public struct RenderLimits: Sendable, Hashable {
    public var maxInputBytes: Int
    public var maxNestingDepth: Int
    public var maxTableDepth: Int
    public var maxElements: Int
    public var maxAttributeLength: Int
    public var maxStyleAttributeLength: Int
    public var maxDataURLLength: Int
    public var maxStylesheetBytes: Int
    public var maxClasses: Int

    public init(maxInputBytes: Int = 4 << 20, maxNestingDepth: Int = 200, maxTableDepth: Int = 24,
                maxElements: Int = 100_000, maxAttributeLength: Int = 16 << 10, maxStyleAttributeLength: Int = 32 << 10,
                maxDataURLLength: Int = 2 << 20, maxStylesheetBytes: Int = 512 << 10, maxClasses: Int = 32) {
        self.maxInputBytes = maxInputBytes
        self.maxNestingDepth = maxNestingDepth
        self.maxTableDepth = maxTableDepth
        self.maxElements = maxElements
        self.maxAttributeLength = maxAttributeLength
        self.maxStyleAttributeLength = maxStyleAttributeLength
        self.maxDataURLLength = maxDataURLLength
        self.maxStylesheetBytes = maxStylesheetBytes
        self.maxClasses = maxClasses
    }

    public static let `default` = RenderLimits()
}

enum NestingLimiter {
    private static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        "keygen", "basefont", "bgsound", "frame", "image", "isindex",
    ]
    private static let optionalEnd: Set<String> = [
        "p", "li", "dt", "dd", "option", "optgroup", "rb", "rt", "rp", "rtc", "tr", "td", "th", "tbody", "thead",
        "tfoot", "colgroup", "caption", "html", "head", "body",
    ]
    private static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title"]

    static func limit(_ html: String, maxDepth: Int, maxTableDepth: Int) -> (html: String, changed: Bool) {
        let bytes = Array(html.utf8)
        var removals: [Range<Int>] = []
        var depth = 0, tableDepth = 0
        var suppressed: [String: Int] = [:]
        var open: [String: Int] = [:]
        var i = 0
        let n = bytes.count
        @inline(__always) func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        @inline(__always) func isAlpha(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
        @inline(__always) func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 12 || b == 13 }

        func skipTagRest(_ j: inout Int) -> Bool {
            var quote: UInt8 = 0
            while j < n {
                let b = bytes[j]
                if quote != 0 {
                    if b == quote { quote = 0 }
                } else if b == 34 || b == 39 {
                    var k = j - 1
                    while k >= 0, isSpace(bytes[k]) { k -= 1 }
                    if k >= 0, bytes[k] == 61 { quote = b }
                } else if b == 62 {
                    j += 1
                    return true
                }
                j += 1
            }
            return false
        }

        while i < n {
            guard bytes[i] == 60 else { i += 1; continue }
            let start = i
            if i + 3 < n, bytes[i + 1] == 33, bytes[i + 2] == 45, bytes[i + 3] == 45 {
                var j = i + 4
                if j < n, bytes[j] == 62 { i = j + 1; continue }
                if j + 1 < n, bytes[j] == 45, bytes[j + 1] == 62 { i = j + 2; continue }
                while j + 2 < n, !(bytes[j] == 45 && bytes[j + 1] == 45 && bytes[j + 2] == 62) { j += 1 }
                i = min(n, j + 3)
                continue
            }
            if i + 1 < n, bytes[i + 1] == 33 || bytes[i + 1] == 63 {
                var j = i + 2
                while j < n, bytes[j] != 62 { j += 1 }
                i = min(n, j + 1)
                continue
            }
            let isEnd = i + 1 < n && bytes[i + 1] == 47
            var j = i + (isEnd ? 2 : 1)
            guard j < n, isAlpha(bytes[j]) else { i += 1; continue }
            var nameBytes: [UInt8] = []
            while j < n, !isSpace(bytes[j]), bytes[j] != 47, bytes[j] != 62 {
                if nameBytes.count < 32 { nameBytes.append(lower(bytes[j])) }
                j += 1
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard skipTagRest(&j) else { break }
            let range = start..<j
            if isEnd {
                if let s = suppressed[name], s > 0 {
                    suppressed[name] = s - 1
                    removals.append(range)
                } else if let o = open[name], o > 0 {
                    open[name] = o - 1
                    depth -= 1
                    if name == "table" { tableDepth -= 1 }
                }
                i = j
                continue
            }
            if rawText.contains(name) {
                var k = j
                let needle = Array("</\(name)".utf8)
                search: while k + needle.count <= n {
                    if bytes[k] == 60 {
                        var match = true
                        for (offset, b) in needle.enumerated() where lower(bytes[k + offset]) != b { match = false; break }
                        if match { break search }
                    }
                    k += 1
                }
                i = k
                continue
            }
            if name == "plaintext" { break }
            if void.contains(name) || optionalEnd.contains(name) { i = j; continue }
            let overTable = name == "table" && tableDepth >= maxTableDepth
            if depth >= maxDepth || overTable {
                suppressed[name, default: 0] += 1
                removals.append(range)
            } else {
                depth += 1
                open[name, default: 0] += 1
                if name == "table" { tableDepth += 1 }
            }
            i = j
        }
        guard !removals.isEmpty else { return (html, false) }
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var cursor = 0
        for r in removals {
            out.append(contentsOf: bytes[cursor..<r.lowerBound])
            cursor = r.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return (String(decoding: out, as: UTF8.self), true)
    }

    static func truncated(_ html: String, maxBytes: Int) -> (html: String, truncated: Bool) {
        guard html.utf8.count > maxBytes else { return (html, false) }
        var bytes = Array(html.utf8.prefix(max(0, maxBytes)))
        var k = bytes.count - 1, continuation = 0
        while k >= 0, bytes[k] & 0xC0 == 0x80, continuation < 3 { k -= 1; continuation += 1 }
        if k >= 0 {
            let lead = bytes[k]
            let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if continuation + 1 < needed { bytes.removeSubrange(k...) }
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }
}
