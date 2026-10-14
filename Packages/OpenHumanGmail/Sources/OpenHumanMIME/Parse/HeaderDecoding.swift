import Foundation
import OpenHumanCore

public enum HeaderDecoder {
    public static func decode(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var out = ""
        var pendingWhitespace = ""
        var lastWasEncoded = false
        var i = value.startIndex
        while i < value.endIndex {
            if value[i...].hasPrefix("=?"), let (decoded, end) = encodedWord(in: value, at: i) {
                if !lastWasEncoded { out += pendingWhitespace }
                pendingWhitespace = ""
                out += decoded
                lastWasEncoded = true
                i = end
                continue
            }
            let c = value[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" {
                pendingWhitespace.append(c == "\r" || c == "\n" ? " " : c)
            } else {
                out += pendingWhitespace
                pendingWhitespace = ""
                out.append(c)
                lastWasEncoded = false
            }
            i = value.index(after: i)
        }
        return out + pendingWhitespace
    }

    private static func encodedWord(in s: String, at start: String.Index) -> (String, String.Index)? {
        let afterOpen = s.index(start, offsetBy: 2)
        guard let q1 = s[afterOpen...].firstIndex(of: "?") else { return nil }
        let charset = String(s[afterOpen..<q1])
        let encStart = s.index(after: q1)
        guard encStart < s.endIndex, let q2 = s[encStart...].firstIndex(of: "?"), s.distance(from: encStart, to: q2) == 1
        else { return nil }
        let encoding = s[encStart].uppercased()
        let textStart = s.index(after: q2)
        guard let close = s[textStart...].range(of: "?=") else { return nil }
        let text = String(s[textStart..<close.lowerBound])
        if charset.isEmpty || text.contains(" ") { return nil }
        let bytes: Data?
        switch encoding {
        case "B": bytes = Data(base64Encoded: padBase64(text))
        case "Q": bytes = decodeQ(text)
        default: return nil
        }
        guard let bytes else { return nil }
        return (CharsetDecoder.decode(bytes, declaredCharset: charset).text, close.upperBound)
    }

    private static func padBase64(_ s: String) -> String {
        let rem = s.count % 4
        return rem == 0 ? s : s + String(repeating: "=", count: 4 - rem)
    }

    private static func decodeQ(_ text: String) -> Data? {
        var out = Data()
        var bytes = Array(text.utf8)[...]
        while let b = bytes.first {
            bytes = bytes.dropFirst()
            switch b {
            case UInt8(ascii: "_"): out.append(0x20)
            case UInt8(ascii: "="):
                guard bytes.count >= 2, let v = UInt8(String(decoding: bytes.prefix(2), as: UTF8.self), radix: 16)
                else { return nil }
                out.append(v)
                bytes = bytes.dropFirst(2)
            default: out.append(b)
            }
        }
        return out
    }

    public static func messageIDs(_ value: String) -> [String] {
        var ids: [String] = []
        var current = ""
        var inside = false
        for c in value {
            switch c {
            case "<":
                inside = true
                current = "<"
            case ">" where inside:
                current.append(">")
                ids.append(current)
                current = ""
                inside = false
            case " ", "\t", "\r", "\n", ",":
                if inside { continue }
                if !current.isEmpty { ids.append(current); current = "" }
            default:
                current.append(c)
            }
        }
        if !current.isEmpty, !inside { ids.append(current) }
        return ids.filter { $0.count > 2 }
    }
}

public enum AddressParser {
    public static func parseList(_ raw: String) -> (addresses: [EmailAddress], warnings: [String]) {
        var addresses: [EmailAddress] = []
        var warnings: [String] = []
        var pending = ""
        for item in splitTopLevel(raw) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let candidate = pending.isEmpty ? trimmed : pending + ", " + trimmed
            if !candidate.contains("@") && !candidate.contains("<") && !candidate.contains(":") {
                pending = candidate
                continue
            }
            pending = ""
            if let colon = topLevelIndex(of: ":", in: candidate) {
                var members = String(candidate[candidate.index(after: colon)...])
                if members.hasSuffix(";") { members.removeLast() }
                let inner = parseList(members)
                addresses += inner.addresses
                warnings += inner.warnings
                continue
            }
            if let mailbox = parseMailbox(candidate) {
                addresses.append(mailbox)
            } else {
                warnings.append("address: unparseable entry skipped")
            }
        }
        if !pending.isEmpty { warnings.append("address: dangling text without an address") }
        return (addresses, warnings)
    }

    public static func parseMailbox(_ raw: String) -> EmailAddress? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = topLevelIndex(of: "<", in: text) {
            guard let close = text[open...].firstIndex(of: ">") else { return nil }
            let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { return nil }
            let name = cleanName(String(text[..<open]))
            return EmailAddress(name: name, email: email)
        }
        let (bare, comment) = stripComments(text)
        let email = bare.trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), !email.contains(" ") else { return nil }
        let name = comment.flatMap { cleanName($0) }
        return EmailAddress(name: name, email: email)
    }

    private static func cleanName(_ raw: String) -> String? {
        var (name, _) = stripComments(raw)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else {
            name = name.replacingOccurrences(of: "\"", with: "")
        }
        name = HeaderDecoder.decode(name).split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    private static func stripComments(_ s: String) -> (String, String?) {
        var out = ""
        var comment = ""
        var firstComment: String?
        var depth = 0
        var inQuote = false
        var escaped = false
        for c in s {
            if escaped { if depth > 0 { comment.append(c) } else { out.append(c) }; escaped = false; continue }
            if c == "\\" { escaped = true; if depth == 0 { out.append(c) }; continue }
            if c == "\"" && depth == 0 { inQuote.toggle(); out.append(c); continue }
            if !inQuote && c == "(" { depth += 1; if depth == 1 { comment = "" } else { comment.append(c) }; continue }
            if !inQuote && c == ")" && depth > 0 {
                depth -= 1
                if depth == 0 { if firstComment == nil { firstComment = comment } } else { comment.append(c) }
                continue
            }
            if depth > 0 { comment.append(c) } else { out.append(c) }
        }
        return (out, firstComment)
    }

    static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false, escaped = false
        var paren = 0, angle = 0
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\": escaped = true; current.append(c)
            case "\"" where paren == 0: inQuote.toggle(); current.append(c)
            case "(" where !inQuote: paren += 1; current.append(c)
            case ")" where !inQuote && paren > 0: paren -= 1; current.append(c)
            case "<" where !inQuote && paren == 0: angle += 1; current.append(c)
            case ">" where !inQuote && paren == 0 && angle > 0: angle -= 1; current.append(c)
            case "," where !inQuote && paren == 0 && angle == 0:
                parts.append(current); current = ""
            case ";" where !inQuote && paren == 0 && angle == 0:
                current.append(c); parts.append(current); current = ""
            default: current.append(c)
            }
        }
        parts.append(current)
        var joined: [String] = []
        var group: String?
        for p in parts {
            if var g = group {
                g += "," + p
                if p.trimmingCharacters(in: .whitespaces).hasSuffix(";") { joined.append(g); group = nil } else { group = g }
            } else if topLevelIndex(of: ":", in: p) != nil, !p.trimmingCharacters(in: .whitespaces).hasSuffix(";") {
                group = p
            } else {
                joined.append(p)
            }
        }
        if let group { joined.append(group) }
        return joined
    }

    private static func topLevelIndex(of ch: Character, in s: String) -> String.Index? {
        var inQuote = false, escaped = false
        var paren = 0, angle = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            defer { i = s.index(after: i) }
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" && paren == 0 { inQuote.toggle(); continue }
            if inQuote { continue }
            if c == "(" { paren += 1; continue }
            if c == ")" && paren > 0 { paren -= 1; continue }
            if paren > 0 { continue }
            if c == ch && angle == 0 { return i }
            if c == "<" { angle += 1 } else if c == ">" && angle > 0 { angle -= 1 }
        }
        return nil
    }
}

public enum MIMEDate {
    public static func parse(_ raw: String) -> Date? {
        var s = raw
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).joined(separator: " ")
        if let comma = s.firstIndex(of: ","), s.distance(from: s.startIndex, to: comma) <= 9 {
            s = String(s[s.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        let formats = ["d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yy HH:mm:ss Z", "d MMM yy HH:mm Z",
                       "d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm zzz", "d MMM yy HH:mm:ss zzz",
                       "d MMM yyyy HH:mm:ss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in formats {
            formatter.dateFormat = format
            guard let date = formatter.date(from: s) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "GMT")!
            let year = calendar.component(.year, from: date)
            if year < 100 {
                return calendar.date(byAdding: .year, value: year < 50 ? 2000 : 1900, to: date)
            }
            return date
        }
        return nil
    }
}
