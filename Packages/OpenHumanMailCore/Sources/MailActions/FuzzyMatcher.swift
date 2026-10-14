import Foundation

public struct FuzzyMatch: Hashable, Sendable {
    public let score: Int
    public let positions: [Int]
}

public struct FuzzyMatcher: Sendable {
    public let query: String
    private let needle: [Character]

    public init(_ query: String) {
        self.query = query
        needle = Array(Self.fold(query).filter { !$0.isWhitespace })
    }

    public var isEmpty: Bool { needle.isEmpty }

    public func match(_ candidate: String) -> FuzzyMatch? {
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        let hay = Array(Self.fold(candidate))
        guard hay.count >= needle.count else { return nil }
        var latest = [Int](repeating: 0, count: needle.count)
        var j = hay.count - 1
        for n in stride(from: needle.count - 1, through: 0, by: -1) {
            while j >= 0, hay[j] != needle[n] { j -= 1 }
            guard j >= 0 else { return nil }
            latest[n] = j
            j -= 1
        }
        var positions: [Int] = []
        positions.reserveCapacity(needle.count)
        var start = 0
        for (n, character) in needle.enumerated() {
            let limit = latest[n] + 1
            var chosen: Int?
            var firstPlain: Int?
            var i = start
            while i < limit {
                if hay[i] == character {
                    if Self.isWordStart(hay, i) || (positions.last.map { $0 == i - 1 } ?? false) {
                        chosen = i
                        break
                    }
                    if firstPlain == nil { firstPlain = i }
                }
                i += 1
            }
            guard let index = chosen ?? firstPlain else { return nil }
            positions.append(index)
            start = index + 1
        }
        return FuzzyMatch(score: score(positions, hay), positions: positions)
    }

    public func match(title: String, keywords: [String]) -> FuzzyMatch? {
        let titleMatch = match(title)
        let keywordScore = keywords.compactMap { match($0)?.score }.max().map { $0 - 4 }
        switch (titleMatch, keywordScore) {
        case (let t?, let k?): return FuzzyMatch(score: max(t.score, k), positions: t.positions)
        case (let t?, nil): return t
        case (nil, let k?): return FuzzyMatch(score: k, positions: [])
        case (nil, nil): return nil
        }
    }

    private func score(_ positions: [Int], _ hay: [Character]) -> Int {
        var score = 0
        for (n, p) in positions.enumerated() {
            score += 1
            if Self.isWordStart(hay, p) { score += 8 }
            if n > 0, positions[n - 1] == p - 1 { score += 5 }
        }
        if positions.first == 0 { score += 6 }
        if positions.count == hay.count { score += 10 }
        if let first = positions.first, let last = positions.last {
            score -= 2 * (last - first + 1 - positions.count)
        }
        score -= hay.count / 16
        return score
    }

    static func isWordStart(_ hay: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let previous = hay[i - 1]
        return !(previous.isLetter || previous.isNumber)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
