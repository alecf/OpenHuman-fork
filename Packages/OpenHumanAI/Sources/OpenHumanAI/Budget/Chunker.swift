import Foundation

public enum Chunker {
    enum Level: Int, CaseIterable {
        case paragraph, line, sentence, word, character
    }

    public static func split(_ text: String, fits: (String) async -> Bool) async throws -> [String] {
        try await split(text, level: .paragraph, fits: fits).filter { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func split(_ text: String, level: Level, fits: (String) async -> Bool) async throws -> [String] {
        if await fits(text) { return [text] }
        if level == .character { return try await hardSplit(text, fits: fits) }
        let units = segment(text, level: level)
        guard let next = Level(rawValue: level.rawValue + 1) else { return try await hardSplit(text, fits: fits) }
        if units.count <= 1 { return try await split(text, level: next, fits: fits) }

        var pieces: [String] = []
        var start = 0
        while start < units.count {
            func run(_ end: Int) -> String { units[start..<end].joined() }
            var good = start
            var bad = units.count + 1
            var step = 1
            while start + step <= units.count {
                if await fits(run(start + step)) {
                    good = start + step
                    step *= 2
                } else {
                    bad = start + step
                    break
                }
            }
            var low = good
            var high = min(bad - 1, units.count)
            while low < high {
                let mid = (low + high + 1) / 2
                if await fits(run(mid)) { low = mid } else { high = mid - 1 }
            }
            if low == start {
                pieces += try await split(units[start], level: next, fits: fits)
                start += 1
            } else {
                pieces.append(run(low))
                start = low
            }
        }
        return pieces
    }

    private static func hardSplit(_ text: String, fits: (String) async -> Bool) async throws -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if await fits(String(rest)) {
                pieces.append(String(rest))
                break
            }
            var low = 0
            var high = rest.count
            while low < high {
                let mid = (low + high + 1) / 2
                if await fits(String(rest.prefix(mid))) { low = mid } else { high = mid - 1 }
            }
            guard low > 0 else { throw AIError.contextOverflow(counted: 1, limit: 0) }
            pieces.append(String(rest.prefix(low)))
            rest = rest.dropFirst(low)
        }
        return pieces
    }

    static func segment(_ text: String, level: Level) -> [String] {
        var units: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        func flush() {
            if !current.isEmpty { units.append(current) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            index += 1
            switch level {
            case .paragraph:
                if character.isNewline {
                    var look = index
                    while look < characters.count, characters[look].isWhitespace, !characters[look].isNewline { look += 1 }
                    if look < characters.count, characters[look].isNewline {
                        while index < characters.count, characters[index].isWhitespace {
                            current.append(characters[index])
                            index += 1
                        }
                        flush()
                    }
                }
            case .line:
                if character.isNewline { flush() }
            case .sentence:
                if character == "." || character == "!" || character == "?" || character == "\u{3002}" {
                    if index >= characters.count || characters[index].isWhitespace {
                        while index < characters.count, characters[index].isWhitespace {
                            current.append(characters[index])
                            index += 1
                        }
                        flush()
                    }
                }
            case .word:
                if character.isWhitespace {
                    while index < characters.count, characters[index].isWhitespace {
                        current.append(characters[index])
                        index += 1
                    }
                    flush()
                }
            case .character:
                flush()
            }
        }
        flush()
        return units
    }

    public static func truncate(_ text: String, marker: String = AIPolicy.truncationMarker,
                                fits: (String) async -> Bool) async throws -> String
    {
        if await fits(text) { return text }
        let characters = Array(text)
        for level in [Level.sentence, .word, .character] {
            var ends: [Int] = []
            if level == .character {
                ends = characters.count > 1 ? Array(1..<characters.count) : []
            } else {
                var offset = 0
                for unit in segment(text, level: level).dropLast() {
                    offset += unit.count
                    ends.append(offset)
                }
            }
            var low = -1
            var high = ends.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if await fits(cut(String(characters[0..<ends[mid]]), marker: marker)) { low = mid } else { high = mid - 1 }
            }
            if low >= 0 { return cut(String(characters[0..<ends[low]]), marker: marker) }
        }
        if await fits(marker) { return marker }
        throw AIError.contextOverflow(counted: TokenHeuristic.count(marker), limit: 0)
    }

    private static func cut(_ prefix: String, marker: String) -> String {
        var trimmed = prefix
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return trimmed + "\n" + marker
    }
}
