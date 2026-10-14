import Foundation
import Synchronization

public final class ByteLevelBPETokenizer: @unchecked Sendable {
    public enum LoadError: Error, Sendable, Hashable {
        case unreadable
        case unsupported(String)
    }

    public static let qwen2SplitPattern =
        #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#

    public let vocab: [String: Int]
    private let tokens: [Int: String]
    private let mergeRanks: [String: Int]
    public let addedTokens: [String: Int]
    private let specialIDs: Set<Int>
    private let split: NSRegularExpression
    private let addedSplit: NSRegularExpression?
    private let normalizesNFC: Bool
    public let eosToken: String?
    private let cache = Mutex<[String: [Int]]>([:])

    static let byteToChar: [UInt8: Character] = {
        var bytes: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var chars = bytes
        var extra = 0
        for b in 0..<256 where !bytes.contains(b) {
            bytes.append(b)
            chars.append(256 + extra)
            extra += 1
        }
        var map: [UInt8: Character] = [:]
        for (b, c) in zip(bytes, chars) { map[UInt8(b)] = Character(UnicodeScalar(UInt32(c))!) }
        return map
    }()

    private static let scalarToByte: [UnicodeScalar: UInt8] = {
        Dictionary(uniqueKeysWithValues: byteToChar.map { ($1.unicodeScalars.first!, $0) })
    }()

    public init(vocab: [String: Int], merges: [String], addedTokens: [String: (id: Int, special: Bool)] = [:],
                splitPattern: String = ByteLevelBPETokenizer.qwen2SplitPattern, normalizesNFC: Bool = true,
                eosToken: String? = nil) throws {
        var vocabulary = vocab
        for (content, entry) in addedTokens { vocabulary[content] = entry.id }
        self.vocab = vocabulary
        self.tokens = Dictionary(vocabulary.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var ranks: [String: Int] = [:]
        for (rank, merge) in merges.enumerated() where ranks[merge] == nil { ranks[merge] = rank }
        self.mergeRanks = ranks
        self.addedTokens = addedTokens.mapValues(\.id)
        self.specialIDs = Set(addedTokens.values.filter(\.special).map(\.id))
        do {
            self.split = try NSRegularExpression(pattern: splitPattern)
        } catch {
            throw LoadError.unsupported("split pattern")
        }
        let contents = addedTokens.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        if contents.isEmpty {
            self.addedSplit = nil
        } else {
            self.addedSplit = try? NSRegularExpression(
                pattern: contents.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))
        }
        self.normalizesNFC = normalizesNFC
        self.eosToken = eosToken
    }

    public convenience init(tokenizerJSON data: Data, eosToken: String? = nil) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int]
        else { throw LoadError.unreadable }
        if let type = model["type"] as? String, type != "BPE" { throw LoadError.unsupported("model type \(type)") }
        let merges: [String]
        if let strings = model["merges"] as? [String] {
            merges = strings
        } else if let pairs = model["merges"] as? [[String]] {
            merges = pairs.compactMap { $0.count == 2 ? $0[0] + " " + $0[1] : nil }
        } else {
            throw LoadError.unreadable
        }
        var added: [String: (id: Int, special: Bool)] = [:]
        for entry in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? Int, let content = entry["content"] as? String else { continue }
            added[content] = (id, entry["special"] as? Bool ?? false)
        }
        let normalizer = (root["normalizer"] as? [String: Any])?["type"] as? String
        try self.init(vocab: vocab, merges: merges, addedTokens: added,
                      splitPattern: Self.splitPattern(in: root["pre_tokenizer"]) ?? Self.qwen2SplitPattern,
                      normalizesNFC: normalizer == nil || normalizer == "NFC", eosToken: eosToken)
    }

    public convenience init(contentsOf url: URL, eosToken: String? = nil) throws {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable }
        try self.init(tokenizerJSON: data, eosToken: eosToken)
    }

    static func splitPattern(in node: Any?) -> String? {
        guard let node = node as? [String: Any] else { return nil }
        if node["type"] as? String == "Split", let pattern = node["pattern"] as? [String: Any],
           let regex = pattern["Regex"] as? String {
            return regex
        }
        for child in node["pretokenizers"] as? [Any] ?? [] {
            if let found = splitPattern(in: child) { return found }
        }
        return nil
    }

    public func id(for token: String) -> Int? { vocab[token] }
    public func token(for id: Int) -> String? { tokens[id] }
    public func isSpecial(_ id: Int) -> Bool { specialIDs.contains(id) }

    public func encode(_ text: String, allowSpecialTokens: Bool = true) -> [Int] {
        let normalized = normalizesNFC ? text.precomposedStringWithCanonicalMapping : text
        guard allowSpecialTokens, let addedSplit else { return encodeOrdinary(normalized) }
        var ids: [Int] = []
        let ns = normalized as NSString
        var cursor = 0
        for match in addedSplit.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                ids += encodeOrdinary(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            if let id = addedTokens[ns.substring(with: match.range)] { ids.append(id) }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { ids += encodeOrdinary(ns.substring(from: cursor)) }
        return ids
    }

    private func encodeOrdinary(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var ids: [Int] = []
        for match in split.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: match.range)
            let mapped = String(piece.utf8.map { Self.byteToChar[$0]! })
            ids += bpe(mapped)
        }
        return ids
    }

    func bpe(_ word: String) -> [Int] {
        if let hit = cache.withLock({ $0[word] }) { return hit }
        var parts = word.unicodeScalars.map { String($0) }
        while parts.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0..<(parts.count - 1) {
                if let rank = mergeRanks[parts[index] + " " + parts[index + 1]], rank < (best?.rank ?? .max) {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            let left = parts[best.index], right = parts[best.index + 1]
            var merged: [String] = []
            merged.reserveCapacity(parts.count)
            var index = 0
            while index < parts.count {
                if index < parts.count - 1, parts[index] == left, parts[index + 1] == right {
                    merged.append(left + right)
                    index += 2
                } else {
                    merged.append(parts[index])
                    index += 1
                }
            }
            parts = merged
        }
        var ids: [Int] = []
        for part in parts {
            if let id = vocab[part] {
                ids.append(id)
            } else {
                ids += part.unicodeScalars.compactMap { vocab[String($0)] }
            }
        }
        cache.withLock { cache in
            if cache.count > 50_000 { cache.removeAll(keepingCapacity: true) }
            cache[word] = ids
        }
        return ids
    }

    public func decode(_ ids: [Int], skipSpecialTokens: Bool = false) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = tokens[id] else { continue }
            if addedTokens[token] != nil {
                if skipSpecialTokens && specialIDs.contains(id) { continue }
                bytes += Array(token.utf8)
                continue
            }
            for scalar in token.unicodeScalars {
                if let byte = Self.scalarToByte[scalar] {
                    bytes.append(byte)
                } else {
                    bytes += Array(String(scalar).utf8)
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum Qwen3ChatTemplate {
    public static let imStart = "<|im_start|>"
    public static let imEnd = "<|im_end|>"
    public static let thinkOpen = "<think>"
    public static let thinkClose = "</think>"
    public static let eosToken = imEnd

    public enum TemplateError: Error, Sendable, Hashable { case missingToken(String) }

    public static func render(system: String, user: String) -> String {
        "\(imStart)system\n\(system)\(imEnd)\n\(imStart)user\n\(user)\(imEnd)\n\(imStart)assistant\n\(thinkOpen)\n\n\(thinkClose)\n\n"
    }

    public static func encode(_ messages: [(role: String, content: String)], tokenizer: ByteLevelBPETokenizer) throws -> [Int] {
        func special(_ token: String) throws -> Int {
            guard let id = tokenizer.addedTokens[token] ?? tokenizer.id(for: token) else {
                throw TemplateError.missingToken(token)
            }
            return id
        }
        let start = try special(imStart), end = try special(imEnd)
        var ids: [Int] = []
        for message in messages {
            ids.append(start)
            ids += tokenizer.encode(message.role + "\n" + message.content, allowSpecialTokens: false)
            ids.append(end)
            ids += tokenizer.encode("\n", allowSpecialTokens: false)
        }
        ids.append(start)
        ids += tokenizer.encode("assistant\n", allowSpecialTokens: false)
        ids.append(try special(thinkOpen))
        ids += tokenizer.encode("\n\n", allowSpecialTokens: false)
        ids.append(try special(thinkClose))
        ids += tokenizer.encode("\n\n", allowSpecialTokens: false)
        return ids
    }
}
