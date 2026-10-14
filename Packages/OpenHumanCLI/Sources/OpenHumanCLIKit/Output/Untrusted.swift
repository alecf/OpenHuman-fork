import Foundation

public enum ContentSanitizer {
    public static func sanitize(_ text: String, maxBytes: Int? = nil) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in stripTags(text).unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar == "\n" || scalar == "\t": scalars.append(scalar)
            case .control, .format: continue
            case .lineSeparator, .paragraphSeparator: scalars.append("\n")
            default: scalars.append(scalar)
            }
        }
        var out = ""
        var spaces = false, newlines = 0
        for ch in String(scalars) {
            if ch == "\n" || ch == "\r\n" {
                newlines += 1; spaces = false
            } else if ch == " " || ch == "\t" || ch.isWhitespace {
                if newlines == 0 { spaces = true }
            } else {
                if !out.isEmpty { if newlines > 0 { out += newlines >= 2 ? "\n\n" : "\n" } else if spaces { out += " " } }
                newlines = 0; spaces = false
                out.append(ch)
            }
        }
        guard let maxBytes, out.utf8.count > maxBytes else { return out }
        var cut = out.startIndex
        var used = 0
        for index in out.indices {
            let next = out.index(after: index)
            let size = out[index..<next].utf8.count
            if used + size > maxBytes { break }
            used += size
            cut = next
        }
        return String(out[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + " …[truncated]"
    }

    static func stripTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "<", let close = text[index...].firstIndex(of: ">") {
                let after = text.index(after: index)
                if after < text.endIndex, text[after].isLetter || "/!?".contains(text[after]) {
                    index = text.index(after: close)
                    continue
                }
            }
            out.append(ch)
            index = text.index(after: index)
        }
        return out
    }
}

public struct UntrustedWrapper: Sendable {
    public let nonce: String
    public init(nonce: String) { self.nonce = nonce }

    public static func makeNonce() -> String {
        String((0..<6).map { _ in "0123456789abcdef".randomElement()! })
    }

    public func wrap(_ text: String) -> String {
        let safe = text.replacingOccurrences(of: "⟦/untrusted:", with: "⟦/untrusted-escaped:")
        return "⟦untrusted:\(nonce)⟧ \(safe) ⟦/untrusted:\(nonce)⟧"
    }
}

struct ContentPolicy: Sendable {
    var wrapper: UntrustedWrapper?
    var sanitize: Bool
    var maxBodyBytes: Int

    func apply(_ value: OutValue) -> OutValue {
        guard wrapper != nil || sanitize else { return value }
        return value.mapStrings { leaf in
            switch leaf {
            case .string(let s): return s
            case .untrusted(let s):
                let clean = sanitize ? ContentSanitizer.sanitize(s) : s
                return wrapper?.wrap(clean) ?? clean
            case .body(let s):
                let clean = sanitize ? ContentSanitizer.sanitize(s, maxBytes: maxBodyBytes) : s
                return wrapper?.wrap(clean) ?? clean
            default: return leaf.text
            }
        }
    }
}
