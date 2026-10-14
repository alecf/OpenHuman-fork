import Foundation
import OpenHumanLinks

public enum MailtoLink {
    public static func parse(_ url: URL) -> Result<ComposePrefill, MailLinkError> {
        parse(string: url.absoluteString)
    }

    public static func parse(string raw: String) -> Result<ComposePrefill, MailLinkError> {
        guard raw.utf8.count <= LinkGrammar.maxURLBytes else { return .failure(.tooLong) }
        guard raw.prefix(7).lowercased() == "mailto:" else { return .failure(.wrongScheme) }
        let rest = raw.dropFirst(7)
        let path = rest.prefix { $0 != "?" }
        let query = rest.dropFirst(path.count + (rest.count > path.count ? 1 : 0))

        var to: [String] = []
        var cc: [String] = []
        var subject: String?
        var body: String?
        var sawBcc = false

        func decode(_ s: Substring) -> String? { String(s).removingPercentEncoding }
        func addresses(_ list: String) -> [String] {
            list.split(separator: ",").map { bareAddress(String($0)) }.filter { !$0.isEmpty }
        }

        guard let decodedPath = decode(path) else { return .failure(.invalidEncoding) }
        to += addresses(decodedPath)
        for field in query.split(separator: "&") where !field.isEmpty {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0])?.lowercased(), let value = parts.count > 1 ? decode(parts[1]) : "" else {
                return .failure(.invalidEncoding)
            }
            switch name {
            case "to": to += addresses(value)
            case "cc": cc += addresses(value)
            case "bcc": sawBcc = true
            case "subject": if subject == nil { subject = value }
            case "body": if body == nil { body = value }
            default: continue
            }
        }
        guard !to.isEmpty || !cc.isEmpty || subject != nil || body != nil else { return .failure(.invalidAddress) }
        let candidate = MailLink.compose(ComposePrefill(to: to, cc: cc, subject: subject, body: body))
        switch MailLinkParser.parse(string: MailLinkBuilder.string(for: candidate)) {
        case .success(.compose(var prefill)):
            prefill.droppedBcc = sawBcc
            return .success(prefill)
        case .success:
            return .failure(.unknownRoute)
        case .failure(let error):
            return .failure(error)
        }
    }

    static func bareAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            s = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
