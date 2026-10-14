import Foundation

public enum InlineParts {
    public static func contentID(from url: URL) -> String? {
        contentID(fromString: url.absoluteString)
    }

    public static func contentID(fromString raw: String) -> String? {
        let lower = raw.lowercased()
        let rest: Substring
        if lower.hasPrefix(URLPolicy.inlinePartScheme + ":") {
            rest = raw.dropFirst(URLPolicy.inlinePartScheme.count + 1)
        } else if lower.hasPrefix("cid:") {
            rest = raw.dropFirst(4)
        } else {
            return nil
        }
        let decoded = String(rest).removingPercentEncoding ?? String(rest)
        let id = normalize(decoded)
        return id.isEmpty ? nil : id
    }

    public static func normalize(_ contentID: String) -> String {
        var id = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<"), id.hasSuffix(">"), id.count >= 2 { id = String(id.dropFirst().dropLast()) }
        return id
    }

    public static func matches(_ a: String, _ b: String) -> Bool {
        let (x, y) = (normalize(a), normalize(b))
        return x == y || x.lowercased() == y.lowercased()
    }

    public static func urlString(forContentID contentID: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@!$&'()*+,;=")
        let id = normalize(contentID)
        return URLPolicy.inlinePartScheme + ":" + (id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)
    }
}
