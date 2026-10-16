import Foundation

public enum SearchHeaderMatch: Hashable, Sendable, Comparable {
    case none
    case someWords(fraction: Double)
    case allWords
    case subjectPhrase
    case senderAddress
    case senderName

    public var value: Double {
        switch self {
        case .none: 0
        case .someWords(let fraction): 0.25 * min(max(fraction, 0), 1)
        case .allWords: 0.5
        case .subjectPhrase: 0.75
        case .senderAddress, .senderName: 1
        }
    }

    public var label: String {
        switch self {
        case .none: "text match only"
        case .someWords: "some words in sender or subject"
        case .allWords: "all words in sender or subject"
        case .subjectPhrase: "subject phrase match"
        case .senderAddress: "sender address match"
        case .senderName: "sender name match"
        }
    }

    private var order: Int {
        switch self {
        case .none: 0
        case .someWords: 1
        case .allWords: 2
        case .subjectPhrase: 3
        case .senderAddress: 4
        case .senderName: 5
        }
    }

    public static func < (lhs: SearchHeaderMatch, rhs: SearchHeaderMatch) -> Bool {
        if lhs.value != rhs.value { return lhs.value < rhs.value }
        return lhs.order < rhs.order
    }
}

public struct SearchHeaderTerms: Hashable, Sendable {
    public let words: [String]
    public let rawWords: [String]

    public init(words rawWords: [String]) {
        var raw: [String] = [], folded: [String] = []
        for word in rawWords {
            let f = Self.fold(word)
            guard !f.isEmpty else { continue }
            raw.append(word)
            folded.append(f)
        }
        self.rawWords = raw
        self.words = folded
    }

    public init(query: SearchQuery) {
        var words: [String] = []
        for term in query.terms {
            if case let .text(text, field) = term, field == nil || field == .subject || field == .participants {
                words.append(text)
            }
        }
        self.init(words: words)
    }

    public var isEmpty: Bool { words.isEmpty }

    public var phrase: String { words.joined(separator: " ") }

    public var ftsPhrase: String? {
        guard rawWords.count >= 2 else { return nil }
        let text = rawWords.joined(separator: " ")
        return text.unicodeScalars.count >= SearchCompiler.minimumTrigramLength ? text : nil
    }

    public func match(subject: String?, fromName: String?, fromEmail: String?) -> SearchHeaderMatch {
        guard !words.isEmpty else { return .none }
        let name = Self.fold(fromName ?? ""), address = Self.fold(fromEmail ?? ""), subj = Self.fold(subject ?? "")
        let inName = words.map { Self.contains(name, $0) }
        if inName.allSatisfy({ $0 }) { return .senderName }
        let inAddress = words.map { Self.contains(address, $0) }
        if zip(inName, inAddress).allSatisfy({ $0 || $1 }) { return .senderAddress }
        if Self.contains(subj, phrase) { return .subjectPhrase }
        let inSubject = words.map { Self.contains(subj, $0) }
        let found = words.indices.filter { inName[$0] || inAddress[$0] || inSubject[$0] }.count
        if found == words.count { return .allWords }
        return found == 0 ? .none : .someWords(fraction: Double(found) / Double(words.count))
    }

    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(out)
    }

    static func contains(_ field: String, _ word: String) -> Bool {
        guard !word.isEmpty, !field.isEmpty else { return false }
        if word.unicodeScalars.contains(where: isUnspacedScript) { return field.contains(word) }
        return (" " + field).contains(" " + word)
    }

    static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }
}

extension SearchQuery {
    public var isRankedByText: Bool { terms.contains { SearchCompiler.ftsExpression($0) != nil } }
}
