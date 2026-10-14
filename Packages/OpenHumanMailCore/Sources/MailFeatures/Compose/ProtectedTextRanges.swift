import Foundation

public enum ProtectedTextRanges {
    nonisolated(unsafe) private static let patterns: [NSRegularExpression] = [
        #";;[A-Za-z0-9_\-]*"#,
        #"\{\{[A-Za-z0-9_+\-]*(?:\}\})?"#,
        #"(?i)\b(?:https?://|mailto:)[^\s<>"]*"#,
        #"[^\s<>()\[\],;:"@]+@[^\s<>()\[\],;:"@]*"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func find(in text: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []
        for pattern in patterns {
            for match in pattern.matches(in: text, range: whole) where match.range.length > 0 {
                ranges.append(match.range)
            }
        }
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public static func touches(_ range: NSRange, _ protected: [NSRange]) -> Bool {
        protected.contains { p in
            if range.length == 0 { return range.location >= p.location && range.location <= NSMaxRange(p) }
            return NSIntersectionRange(range, p).length > 0
        }
    }

    public static func filter<Item>(_ items: [Item], in text: String, range: (Item) -> NSRange) -> [Item] {
        guard !items.isEmpty else { return items }
        let protected = find(in: text)
        guard !protected.isEmpty else { return items }
        return items.filter { !touches(range($0), protected) }
    }
}
