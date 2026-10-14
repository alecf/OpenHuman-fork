import Foundation

public enum PlainTextFormat: Sendable, Hashable, Codable {
    case fixed
    case flowed(delSp: Bool)
}

public struct PlainTextDocument: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case body(String)
        case quote(String, depth: Int)
        case signature(String)

        public var text: String {
            switch self {
            case .body(let t), .quote(let t, _), .signature(let t): return t
            }
        }
    }

    public let blocks: [Block]
    public let blankLinesBefore: [Int]

    public init(blocks: [Block], blankLinesBefore: [Int] = []) {
        self.blocks = blocks
        self.blankLinesBefore = blankLinesBefore
    }

    public func blankLines(before index: Int) -> Int {
        guard index > 0 else { return 0 }
        return blankLinesBefore.indices.contains(index) ? blankLinesBefore[index] : 1
    }

    public static func parse(_ text: String, format: PlainTextFormat = .fixed,
                             maxBytes: Int = RenderLimits.default.maxInputBytes) -> PlainTextDocument {
        let input = NestingLimiter.truncated(text, maxBytes: maxBytes).html
        let normalized = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let raw = normalized.components(separatedBy: "\n")
        let lines: [Line]
        switch format {
        case .fixed: lines = raw.map(fixedLine)
        case .flowed(let delSp): lines = flowedLines(raw, delSp: delSp)
        }
        return build(lines)
    }

    struct Line {
        var depth: Int
        var text: String
        var isSignatureSeparator: Bool
        var raw: String
    }

    static func fixedLine(_ line: String) -> Line {
        if line == "-- " || line == "--" { return Line(depth: 0, text: "", isSignatureSeparator: true, raw: line) }
        let (depth, content) = quoteDepth(of: line)
        return Line(depth: depth, text: content, isSignatureSeparator: false, raw: line)
    }

    static func flowedLines(_ raw: [String], delSp: Bool) -> [Line] {
        var out: [Line] = []
        var pending: Line?
        var pendingFlowed = false
        for line in raw {
            var depth = 0
            var rest = Substring(line)
            while rest.first == ">" { depth += 1; rest = rest.dropFirst() }
            if rest.first == " " { rest = rest.dropFirst() }
            let isSeparator = depth == 0 && rest == "-- "
            let flowed = !isSeparator && rest.hasSuffix(" ")
            var content = String(rest)
            if flowed, delSp { content.removeLast() }
            if var p = pending, pendingFlowed, p.depth == depth, !isSeparator {
                p.text += content
                p.raw = String(repeating: ">", count: depth) + (depth > 0 ? " " : "") + p.text
                pending = p
            } else {
                if let p = pending { out.append(p) }
                let text = isSeparator ? "" : content
                pending = Line(depth: depth, text: text, isSignatureSeparator: isSeparator,
                               raw: String(repeating: ">", count: depth) + (depth > 0 ? " " : "") + text)
            }
            pendingFlowed = flowed
        }
        if let p = pending { out.append(p) }
        return out
    }

    static func build(_ lines: [Line]) -> PlainTextDocument {
        var blocks: [Block] = []
        var gaps: [Int] = []
        var pendingGap = 0
        var kind: (quote: Int, signature: Bool) = (0, false)
        var run: [String] = []
        var inSignature = false

        func flush() {
            var trailing = 0
            while let last = run.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                run.removeLast()
                trailing += 1
            }
            var leading = 0
            while let first = run.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                run.removeFirst()
                leading += 1
            }
            if !run.isEmpty {
                let text = run.joined(separator: "\n")
                if kind.signature {
                    blocks.append(.signature(text))
                    gaps.append(pendingGap)
                } else if kind.quote > 0 {
                    blocks.append(.quote(text, depth: kind.quote))
                    gaps.append(pendingGap + leading)
                } else {
                    blocks.append(.body(text))
                    gaps.append(pendingGap + leading)
                }
                pendingGap = trailing
            } else {
                pendingGap += trailing
            }
            run = []
        }

        for line in lines {
            if !inSignature, line.isSignatureSeparator {
                flush()
                inSignature = true
                kind = (0, true)
                continue
            }
            if inSignature {
                run.append(line.raw)
                continue
            }
            if line.depth != kind.quote {
                flush()
                kind = (line.depth, false)
            }
            run.append(line.text)
        }
        flush()
        return PlainTextDocument(blocks: blocks, blankLinesBefore: gaps)
    }

    static func quoteDepth(of line: String) -> (Int, String) {
        var depth = 0
        var rest = Substring(line)
        while true {
            let trimmed = rest.drop(while: { $0 == " " })
            guard trimmed.first == ">" else { break }
            depth += 1
            rest = trimmed.dropFirst()
        }
        if depth > 0, rest.first == " " { rest = rest.dropFirst() }
        return (depth, depth > 0 ? String(rest) : line)
    }
}

public struct PlainTextLayout: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case body
        case quote(depth: Int)
        case signature
    }

    public struct Line: Sendable, Equatable {
        public let text: String
        public let role: Role

        public init(text: String, role: Role) {
            self.text = text
            self.role = role
        }

        public var depth: Int {
            if case .quote(let depth) = role { return depth }
            return 0
        }
    }

    public static let quoteIndent: Double = 12
    public static let quoteBarWidth: Double = 2
    public static let maxQuoteLevels = 6

    public let lines: [Line]
    public let foldStart: Int?

    public init(lines: [Line], foldStart: Int?) {
        self.lines = lines
        self.foldStart = foldStart
    }

    public init(_ document: PlainTextDocument) {
        var lines: [Line] = []
        var foldStart: Int?
        let folded = Self.firstFoldedBlock(document)
        for (index, block) in document.blocks.enumerated() {
            for _ in 0..<document.blankLines(before: index) { lines.append(Line(text: "", role: .body)) }
            if index == folded { foldStart = lines.count }
            switch block {
            case .body(let text):
                lines += text.components(separatedBy: "\n").map { Line(text: $0, role: .body) }
            case .quote(let text, let depth):
                lines += text.components(separatedBy: "\n").map { Line(text: $0, role: .quote(depth: depth)) }
            case .signature(let text):
                lines.append(Line(text: "-- ", role: .signature))
                lines += text.components(separatedBy: "\n").map { Line(text: $0, role: .signature) }
            }
        }
        self.init(lines: lines, foldStart: foldStart)
    }

    public static func indent(depth: Int) -> Double {
        Double(min(max(depth, 0), maxQuoteLevels)) * quoteIndent
    }

    static func firstFoldedBlock(_ document: PlainTextDocument) -> Int? {
        let lastBody = document.blocks.lastIndex { if case .body = $0 { return true }; return false } ?? -1
        return document.blocks.indices.first { index in
            switch document.blocks[index] {
            case .body: false
            case .quote: index > lastBody
            case .signature: true
            }
        }
    }
}

public enum PlainTextLinks {
    public struct Link: Sendable, Equatable {
        public let range: NSRange
        public let url: URL
    }

    public static func detect(in text: String) -> [Link] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: whole).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return nil }
            return Link(range: match.range, url: url)
        }
    }
}

public enum TextDirection: Sendable, Equatable {
    case leftToRight, rightToLeft

    public static func firstStrong(in text: String) -> TextDirection? {
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar) { return .rightToLeft }
            if scalar.properties.isAlphabetic { return .leftToRight }
        }
        return nil
    }

    static func isRightToLeft(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        case 0x200F, 0x202B, 0x202E, 0x2067: return true
        default: return false
        }
    }
}
