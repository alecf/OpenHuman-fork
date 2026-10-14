import Foundation

struct StreamCapper {
    let maxTokens: Int?
    private(set) var text = ""
    private(set) var truncated = false
    private var tally = TokenHeuristic.Tally()

    init(maxTokens: Int?) { self.maxTokens = maxTokens }

    mutating func accept(_ delta: String) -> String {
        guard !truncated else { return "" }
        guard let maxTokens else {
            text += delta
            return delta
        }
        // Reserve one token for the ellipsis so the shown text stays within the cap even at a delta boundary
        let contentLimit = max(0, maxTokens - 1)
        var next = tally
        next.add(delta)
        if next.tokens <= contentLimit {
            tally = next
            text += delta
            return delta
        }
        let ellipsis = "\u{2026}"
        let characters = Array(delta)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            var probe = tally
            probe.add(String(characters[0..<mid]))
            if probe.tokens <= contentLimit { low = mid } else { high = mid - 1 }
        }
        let emitted = String(characters[0..<low]) + ellipsis
        text += emitted
        truncated = true
        return emitted
    }
}

struct SecretGate {
    let sources: [String]
    private var pending = ""

    init(request: AIRequest) {
        sources = request.untrusted.map(\.text) + request.trusted.map(\.text)
    }

    mutating func feed(_ delta: String) throws -> String {
        pending += delta
        guard let lastNewline = pending.lastIndex(of: "\n") else { return "" }
        let ready = String(pending[...lastNewline])
        pending = String(pending[pending.index(after: lastNewline)...])
        try check(ready)
        return ready
    }

    mutating func finish() throws -> String {
        let rest = pending
        pending = ""
        try check(rest)
        return rest
    }

    private func check(_ text: String) throws {
        if let finding = SecretScanner.scan(text, ignoringTextsIn: sources).first {
            throw AIError.outputBlocked(
                "The answer looked like it contained a private key, access token or local file path "
                    + "(\(finding.kind.rawValue)), so it was not shown.")
        }
    }
}

struct SourcesLineFilter {
    private var line = ""
    private var lineIsPassThrough = false
    private(set) var cited: [String] = []
    static let marker = "sources:"

    mutating func feed(_ delta: String) -> String {
        var out = ""
        for character in delta {
            if character == "\n" {
                if lineIsPassThrough {
                    out.append("\n")
                } else if Self.isSources(line) {
                    cited += Self.ids(in: line)
                } else {
                    out += line + "\n"
                }
                line = ""
                lineIsPassThrough = false
                continue
            }
            if lineIsPassThrough {
                out.append(character)
                continue
            }
            line.append(character)
            if !Self.couldBeSources(line) {
                out += line
                line = ""
                lineIsPassThrough = true
            }
        }
        return out
    }

    mutating func finish() -> String {
        defer {
            line = ""
            lineIsPassThrough = false
        }
        if lineIsPassThrough { return "" }
        if Self.isSources(line) {
            cited += Self.ids(in: line)
            return ""
        }
        return line
    }

    private static func normalized(_ line: String) -> String {
        String(line.drop(while: \.isWhitespace)).lowercased()
    }

    static func couldBeSources(_ line: String) -> Bool {
        let text = normalized(line)
        return marker.hasPrefix(text) || text.hasPrefix(marker)
    }

    static func isSources(_ line: String) -> Bool { normalized(line).hasPrefix(marker) }

    static func ids(in line: String) -> [String] {
        let start = line.drop(while: \.isWhitespace).dropFirst(marker.count)
        return start.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]()\"'`.")) }
            .filter { !$0.isEmpty }
    }
}
