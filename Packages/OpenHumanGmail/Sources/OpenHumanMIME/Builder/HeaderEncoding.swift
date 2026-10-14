import Foundation

enum HeaderEncoding {
    static func isPlainASCII(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    static func unstructured(_ s: String) -> String {
        let plain = isPlainASCII(s) && !s.contains("=?") && s.first != " " && s.last != " "
        return plain ? s : encodedWords(s)
    }

    static func encodedWords(_ s: String) -> String {
        var words: [String] = []
        var chunk = [UInt8]()
        func flush() {
            guard !chunk.isEmpty else { return }
            words.append("=?UTF-8?B?" + Data(chunk).base64EncodedString() + "?=")
            chunk = []
        }
        for scalar in s.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            if chunk.count + bytes.count > 45 { flush() }
            chunk += bytes
        }
        flush()
        return words.isEmpty ? "=?UTF-8?B??=" : words.joined(separator: " ")
    }

    static func quotedString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func phrase(_ name: String) -> String {
        if !isPlainASCII(name) || name.contains("=?") || name.first == " " || name.last == " " { return encodedWords(name) }
        let atext = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~ ")
        if name.unicodeScalars.allSatisfy({ atext.contains($0) }) && !name.contains("  ") { return name }
        return quotedString(name)
    }

    static func percentEncode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 48...57, 65...90, 97...122, UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(Unicode.Scalar(b)))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func extendedParameter(_ name: String, _ value: String) -> [String] {
        let encoded = percentEncode(value)
        if encoded.utf8.count <= 60 { return ["\(name)*=UTF-8''\(encoded)"] }
        var chunks: [String] = []
        var current = ""
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let step = encoded[i] == "%" ? 3 : 1
            let end = encoded.index(i, offsetBy: step)
            if current.utf8.count + step > 60 { chunks.append(current); current = "" }
            current += encoded[i..<end]
            i = end
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { index, chunk in
            index == 0 ? "\(name)*0*=UTF-8''\(chunk)" : "\(name)*\(index)*=\(chunk)"
        }
    }

    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            var out = ""
            var width = 0
            for (i, b) in bytes.enumerated() {
                let atEnd = i == bytes.count - 1
                let token: String
                if b == 0x20 || b == 0x09 {
                    token = atEnd ? String(format: "=%02X", b) : String(Unicode.Scalar(b))
                } else if b >= 33 && b <= 126 && b != UInt8(ascii: "=") {
                    token = String(Unicode.Scalar(b))
                } else {
                    token = String(format: "=%02X", b)
                }
                if width + token.utf8.count > 75 && !(atEnd && width + token.utf8.count <= 76) {
                    out += "=\r\n"
                    width = 0
                }
                out += token
                width += token.utf8.count
            }
            lines.append(out)
        }
        return lines.joined(separator: "\r\n")
    }

    static func fold(name: String, value: String) -> String? {
        var out = ""
        var line = name + ":"
        for (i, word) in value.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let w = String(word)
            if i == 0 && w.isEmpty { continue }
            if !w.isEmpty, line.utf8.count + 1 + w.utf8.count > 78 {
                out += line + "\r\n"
                line = ""
            }
            line += " " + w
            if line.utf8.count > 998 { return nil }
        }
        return out + line
    }

    static func hasLineBreakOrControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }
    }
}
