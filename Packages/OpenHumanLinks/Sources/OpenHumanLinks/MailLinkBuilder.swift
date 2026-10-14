import Foundation

public enum MailLinkBuilder {
    public static func url(for link: MailLink) -> URL {
        let string = self.string(for: link)
        guard let url = URL(string: string) else {
            // Unreachable: every component is percent-encoded, so the URL is always valid
            preconditionFailure("MailLinkBuilder produced an invalid URL")
        }
        return url
    }

    public static func string(for link: MailLink) -> String {
        let base = LinkGrammar.scheme + "://"
        switch link {
        case let .thread(account, threadID):
            return base + "thread/" + encode(account.raw) + "/" + encode(threadID)
        case let .draft(account, draftID):
            return base + "draft/" + encode(account.raw) + "/" + encode(draftID)
        case let .review(refs):
            let accounts = Set(refs.map(\.account))
            if accounts.count == 1, let only = accounts.first, let account = only {
                return base + "review?account=" + encode(account.raw) + "&ids="
                    + refs.map { encode($0.draftID) }.joined(separator: ",")
            }
            let items = refs.map { ref in
                (ref.account.map { encode($0.raw) + ":" } ?? "") + encode(ref.draftID)
            }
            return base + "review?ids=" + items.joined(separator: ",")
        case let .search(query, account):
            var s = base + "search?q=" + encode(query)
            if let account { s += "&account=" + encode(account.raw) }
            return s
        case let .compose(p):
            var items: [String] = []
            if let a = p.account { items.append("account=" + encode(a.raw)) }
            if !p.to.isEmpty { items.append("to=" + p.to.map(encode).joined(separator: ",")) }
            if !p.cc.isEmpty { items.append("cc=" + p.cc.map(encode).joined(separator: ",")) }
            if let s = p.subject { items.append("subject=" + encode(s)) }
            if let b = p.body { items.append("body=" + encode(b)) }
            return base + "compose" + (items.isEmpty ? "" : "?" + items.joined(separator: "&"))
        case let .settings(.page(page)):
            return base + "settings/" + encode(page)
        case let .settings(.aiPrompts(promptID)):
            return base + "settings/ai/prompts" + (promptID.map { "/" + encode($0) } ?? "")
        }
    }

    static func encode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "@"):
                out.append(Character(Unicode.Scalar(byte)))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                out += "%" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return out
    }
}
