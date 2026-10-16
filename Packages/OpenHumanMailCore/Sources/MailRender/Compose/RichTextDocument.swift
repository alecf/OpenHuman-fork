import Foundation
import MailModel

public struct RichTextDocument: Sendable, Hashable, Codable {
    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    public indirect enum Block: Sendable, Hashable, Codable {
        case paragraph([Inline])
        case list(ordered: Bool, items: [[Block]], start: Int? = nil)
        case quote([Block])
        case image(InlineImageRef)
    }

    public indirect enum Inline: Sendable, Hashable, Codable {
        case text(String, Marks)
        case link(URL, [Inline])
        case lineBreak
        case mention(Mention)
    }

    public struct Marks: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = Marks(rawValue: 1 << 0)
        public static let italic = Marks(rawValue: 1 << 1)
        public static let underline = Marks(rawValue: 1 << 2)
        public static let strikethrough = Marks(rawValue: 1 << 3)
        public static let code = Marks(rawValue: 1 << 4)
    }

    public var normalized: RichTextDocument {
        RichTextDocument(blocks: Self.normalize(blocks))
    }

    static func normalize(_ blocks: [Block]) -> [Block] {
        blocks.map { block in
            switch block {
            case .paragraph(let inlines):
                let n = normalize(inlines)
                return .paragraph(n == [.lineBreak] ? [] : n)
            case .list(let ordered, let items, let start):
                return .list(ordered: ordered, items: items.map { item in
                    let n = normalize(item)
                    return n == [.paragraph([])] ? [] : n
                }, start: listStart(start, ordered: ordered))
            case .quote(let inner):
                return .quote(normalize(inner))
            case .image:
                return block
            }
        }
    }

    public static let listStartRange = 1...99_999

    public static func listStart(_ start: Int?, ordered: Bool) -> Int? {
        guard ordered, let start, start != 1, listStartRange.contains(start) else { return nil }
        return start
    }

    static func normalize(_ inlines: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for inline in inlines {
            switch inline {
            case .text(let s, let marks) where s.contains("\n"):
                let pieces = s.components(separatedBy: "\n")
                var expanded: [Inline] = []
                for (i, piece) in pieces.enumerated() {
                    if i > 0 { expanded.append(.lineBreak) }
                    expanded.append(.text(piece, marks))
                }
                out = normalize(out + expanded)
            case .text(let s, let marks):
                guard !s.isEmpty else { continue }
                if case .text(let previous, let previousMarks)? = out.last, previousMarks == marks {
                    out[out.count - 1] = .text(previous + s, marks)
                } else {
                    out.append(inline)
                }
            case .link(let url, let inner):
                let n = normalize(inner)
                if !n.isEmpty { out.append(.link(url, n)) }
            case .lineBreak, .mention:
                out.append(inline)
            }
        }
        return out
    }
}

public struct InlineImageRef: Sendable, Hashable, Codable {
    public var contentID: String
    public var width: Int?
    public var height: Int?
    public var alt: String?

    public init(contentID: String, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
        self.contentID = contentID
        self.width = width
        self.height = height
        self.alt = alt
    }
}

public struct Mention: Sendable, Hashable, Codable {
    public var name: String?
    public var email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    public init(_ participant: Participant) {
        self.init(name: participant.name, email: participant.email)
    }

    var label: String { "@" + ((name?.isEmpty == false ? name : nil) ?? email) }
}

public struct SignatureHTML: Sendable, Hashable, Codable {
    public var html: String
    public var text: String?

    public init(html: String, text: String? = nil) {
        self.html = html
        self.text = text
    }
}

public struct ComposeStyle: Sendable, Hashable, Codable {
    public var fontFamily: String?
    public var fontSize: Double?

    public init(fontFamily: String? = nil, fontSize: Double? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }

    public static let `default` = ComposeStyle()
}
