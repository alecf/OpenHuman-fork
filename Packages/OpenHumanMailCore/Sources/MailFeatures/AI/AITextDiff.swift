import Foundation

public enum AITextDiff {
    public enum Kind: Sendable, Hashable { case kept, inserted, deleted }

    public struct Segment: Sendable, Hashable {
        public let kind: Kind
        public let text: String
    }

    static let maxTokens = 600

    public static func segments(from old: String, to new: String) -> [Segment] {
        let a = tokens(old), b = tokens(new)
        guard a.count <= maxTokens, b.count <= maxTokens else {
            return merge([Segment(kind: .deleted, text: old), Segment(kind: .inserted, text: new)].filter { !$0.text.isEmpty })
        }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var out: [Segment] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(Segment(kind: .kept, text: a[i])); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                out.append(Segment(kind: .deleted, text: a[i])); i += 1
            } else {
                out.append(Segment(kind: .inserted, text: b[j])); j += 1
            }
        }
        out += a[i...].map { Segment(kind: .deleted, text: $0) }
        out += b[j...].map { Segment(kind: .inserted, text: $0) }
        return merge(out)
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                inSpace = true
                current.append(character)
            } else {
                if inSpace, !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                inSpace = false
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func merge(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments {
            if let last = out.last, last.kind == segment.kind {
                out[out.count - 1] = Segment(kind: last.kind, text: last.text + segment.text)
            } else {
                out.append(segment)
            }
        }
        return out
    }
}
