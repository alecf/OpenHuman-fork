import Foundation
import OpenHumanCore

public struct DevFeedbackRedactor {
    public static let minimumDenylistLength = 4
    public static let maxOutputLength = 500

    private let denylist: [String]
    private let rules: [(NSRegularExpression, String)]

    public init(denylist: [String] = []) {
        let cleaned = Set(denylist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter { $0.count >= Self.minimumDenylistLength }
        self.denylist = cleaned.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        self.rules = Self.patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }

    static let patterns: [(String, String)] = [
        (#"[A-Za-z][A-Za-z0-9+.\-]{1,15}://[^\s"'<>]+"#, "<url>"),
        (#"[A-Za-z0-9._%+\-]+(?:@|%40)[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#, "<email>"),
        (#"(?i)\b(code|state|client_secret|client_id|secret|password|access_token|refresh_token|id_token|token|code_verifier|login_hint|authorization)("?\s*[=:]\s*"?)[^\s"&,;}]+"#, "$1$2<redacted>"),
        (#"[A-Za-z0-9\-]+\.apps\.googleusercontent\.com"#, "<redacted>"),
        (#"GOCSPX-[A-Za-z0-9_\-]+"#, "<redacted>"),
        (#""[^"\n]*""#, "\"<quoted>\""),
        (#"“[^”\n]*”"#, "“<quoted>”"),
        (#"[A-Za-z0-9_\-+/=.~%]{24,}"#, "<opaque>"),
    ]

    public func scrub(_ text: String) -> String {
        var out = Log.redact(text)
        for entry in denylist where out.range(of: entry, options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: entry, with: "<content>", options: .caseInsensitive)
        }
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        if out.count > Self.maxOutputLength { out = String(out.prefix(Self.maxOutputLength)) + "…" }
        return out
    }
}
