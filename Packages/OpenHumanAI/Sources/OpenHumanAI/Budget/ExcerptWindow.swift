import Foundation

public enum ExcerptWindow {
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "him", "his", "how", "its", "may", "who", "did", "get", "got", "what", "when", "where", "which",
        "with", "that", "this", "from", "they", "them", "then", "than", "there", "their", "about", "would", "could",
        "should", "does", "into", "your", "will", "just", "also", "were", "been", "some", "said", "send", "sent",
        "email", "emails", "mail", "message", "messages", "tell", "find", "show", "please",
    ]

    public static func keywords(in question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    public static func best(in body: String, keywords: [String], width: Int = AIPolicy.askInboxExcerptCharacters) -> String {
        let characters = Array(body)
        guard characters.count > width else { return body }
        let lowered = Array(body.lowercased())
        guard lowered.count == characters.count, !keywords.isEmpty else { return snap(characters, start: 0, width: width) }

        var hits: [Int] = []
        for keyword in keywords {
            let needle = Array(keyword)
            guard !needle.isEmpty, needle.count <= lowered.count else { continue }
            var index = 0
            while index <= lowered.count - needle.count {
                if lowered[index] == needle[0], lowered[index..<(index + needle.count)].elementsEqual(needle) {
                    hits.append(index)
                    index += needle.count
                } else {
                    index += 1
                }
            }
        }
        guard !hits.isEmpty else { return snap(characters, start: 0, width: width) }
        hits.sort()
        var bestStart = hits[0]
        var bestCount = 0
        var right = 0
        for left in hits.indices {
            while right < hits.count, hits[right] - hits[left] < width { right += 1 }
            if right - left > bestCount {
                bestCount = right - left
                bestStart = hits[left]
            }
        }
        let start = max(0, min(bestStart - width / 8, characters.count - width))
        return snap(characters, start: start, width: width)
    }

    private static func snap(_ characters: [Character], start: Int, width: Int) -> String {
        var lower = start
        var upper = min(characters.count, start + width)
        if lower > 0 {
            var cursor = lower
            while cursor < upper, !characters[cursor - 1].isWhitespace { cursor += 1 }
            if cursor < upper { lower = cursor }
        }
        if upper < characters.count {
            var cursor = upper
            while cursor > lower, !characters[cursor].isWhitespace { cursor -= 1 }
            if cursor > lower { upper = cursor }
        }
        var text = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > 0 { text = "\u{2026}" + text }
        if upper < characters.count { text += "\u{2026}" }
        return text
    }
}
