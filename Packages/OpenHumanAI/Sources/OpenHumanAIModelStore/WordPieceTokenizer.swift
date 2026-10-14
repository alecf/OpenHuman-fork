import Foundation

public struct WordPieceTokenizer: Sendable {
    public struct Encoding: Sendable, Hashable {
        public var ids: [Int32]
        public var attentionMask: [Int32]
        public var tokens: [String]
    }

    public enum TokenizerError: Error, Sendable, Hashable {
        case emptyVocabulary
        case missingSpecialToken(String)
    }

    public static let maxCharactersPerWord = 100

    public let vocabulary: [String: Int32]
    public let lowercase: Bool
    public let stripAccents: Bool
    public let unknownToken: String
    public let classToken: String
    public let separatorToken: String
    public let paddingToken: String

    public init(vocabulary: [String: Int32], lowercase: Bool = true, stripAccents: Bool = true,
                unknownToken: String = "[UNK]", classToken: String = "[CLS]", separatorToken: String = "[SEP]",
                paddingToken: String = "[PAD]") throws {
        guard !vocabulary.isEmpty else { throw TokenizerError.emptyVocabulary }
        for special in [unknownToken, classToken, separatorToken, paddingToken] where vocabulary[special] == nil {
            throw TokenizerError.missingSpecialToken(special)
        }
        self.vocabulary = vocabulary
        self.lowercase = lowercase
        self.stripAccents = stripAccents
        self.unknownToken = unknownToken
        self.classToken = classToken
        self.separatorToken = separatorToken
        self.paddingToken = paddingToken
    }

    public init(vocabularyFile url: URL, settings: EmbeddingModelManifest.Tokenizer) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var vocabulary: [String: Int32] = [:]
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .enumerated() {
            let token = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if !token.isEmpty, vocabulary[token] == nil { vocabulary[token] = Int32(index) }
        }
        try self.init(vocabulary: vocabulary, lowercase: settings.lowercase, stripAccents: settings.stripAccents,
                      unknownToken: settings.unknownToken, classToken: settings.classToken,
                      separatorToken: settings.separatorToken, paddingToken: settings.paddingToken)
    }

    public func tokenize(_ text: String) -> [String] {
        basicTokens(text).flatMap(wordPieces)
    }

    public func count(_ text: String) -> Int { tokenize(text).count + 2 }

    public func encode(_ text: String, maxLength: Int, padTo: Int? = nil) -> Encoding {
        let budget = max(0, maxLength - 2)
        let pieces = Array(tokenize(text).prefix(budget))
        let tokens = [classToken] + pieces + [separatorToken]
        var ids = tokens.map { vocabulary[$0] ?? vocabulary[unknownToken] ?? 0 }
        var mask = [Int32](repeating: 1, count: ids.count)
        if let padTo, padTo > ids.count {
            let pad = vocabulary[paddingToken] ?? 0
            ids += [Int32](repeating: pad, count: padTo - ids.count)
            mask += [Int32](repeating: 0, count: padTo - mask.count)
        }
        return Encoding(ids: ids, attentionMask: mask, tokens: tokens)
    }

    func basicTokens(_ text: String) -> [String] {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD { continue }
            if Self.isWhitespace(scalar) {
                cleaned.append(" ")
            } else if Self.isControl(scalar) {
                continue
            } else if Self.isCJK(scalar) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        var words: [String] = []
        for word in String(cleaned).split(separator: " ", omittingEmptySubsequences: true) {
            var piece = String(word)
            if lowercase { piece = piece.lowercased() }
            if stripAccents { piece = Self.withoutAccents(piece) }
            words += Self.splitPunctuation(piece)
        }
        return words
    }

    static func withoutAccents(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            view.append(scalar)
        }
        return String(view)
    }

    static func splitPunctuation(_ word: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            if isPunctuation(scalar) {
                if !current.isEmpty { out.append(String(current)); current = String.UnicodeScalarView() }
                out.append(String(Character(scalar)))
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    func wordPieces(_ word: String) -> [String] {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count <= Self.maxCharactersPerWord else { return [unknownToken] }
        var pieces: [String] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var match: String?
            while start < end {
                var candidate = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { candidate = "##" + candidate }
                if vocabulary[candidate] != nil {
                    match = candidate
                    break
                }
                end -= 1
            }
            guard let match else { return [unknownToken] }
            pieces.append(match)
            start = end
        }
        return pieces
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return true }
        return scalar.properties.generalCategory == .spaceSeparator
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: return true
        default: return false
        }
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [
            0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F,
            0x2B820...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F,
        ]
        return ranges.contains { $0.contains(scalar.value) }
    }
}
