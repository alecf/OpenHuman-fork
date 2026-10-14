import Foundation

enum ContentType {
    static func parse(_ value: String) -> (type: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for c in value {
            if escaped { current.append(c); escaped = false; continue }
            if inQuote && c == "\\" { current.append(c); escaped = true; continue }
            if c == "\"" { inQuote.toggle() }
            if c == ";" && !inQuote { pieces.append(current); current = "" } else { current.append(c) }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var raw: [(String, String)] = []
        for piece in pieces.dropFirst().prefix(200) {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = unescape(String(val.dropFirst().dropLast()))
            }
            if !name.isEmpty { raw.append((name, val)) }
        }
        return (type, resolve2231(raw))
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }

    private static func resolve2231(_ raw: [(String, String)]) -> [String: String] {
        var plain: [String: String] = [:]
        var segments: [String: [Int: (Bool, String)]] = [:]
        for (name, value) in raw {
            guard let star = name.firstIndex(of: "*") else {
                if plain[name] == nil { plain[name] = value }
                continue
            }
            let base = String(name[..<star])
            var rest = String(name[name.index(after: star)...])
            let extended = rest.isEmpty || rest.hasSuffix("*")
            if rest.hasSuffix("*") { rest.removeLast() }
            let index = rest.isEmpty ? 0 : Int(rest)
            guard let index, index >= 0, index < 1000 else { continue }
            if segments[base]?[index] == nil { segments[base, default: [:]][index] = (extended, value) }
        }
        for (base, parts) in segments {
            var bytes = Data()
            var charset: String?
            for index in parts.keys.sorted() {
                let (extended, value) = parts[index]!
                var text = value
                if index == 0, extended {
                    let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 { charset = String(fields[0]); text = String(fields[2]) }
                }
                if extended { bytes.append(percentDecode(text)) } else { bytes.append(contentsOf: text.utf8) }
            }
            let decoded = CharsetDecoder.decode(bytes, declaredCharset: charset ?? "utf-8").text
            plain[base] = decoded
        }
        return plain
    }

    static func percentDecode(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
