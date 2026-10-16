import Foundation

public enum MailLinkParser {
    public static func parse(_ url: URL) -> Result<MailLink, MailLinkError> {
        parse(string: url.absoluteString)
    }

    public static func parse(string: String) -> Result<MailLink, MailLinkError> {
        do { return .success(try parseThrowing(string)) } catch let e as MailLinkError { return .failure(e) } catch {
            return .failure(.invalidEncoding)
        }
    }

    private static func parseThrowing(_ string: String) throws -> MailLink {
        guard string.utf8.count <= LinkGrammar.maxURLBytes else { throw MailLinkError.tooLong }
        guard let comps = URLComponents(string: string) else { throw MailLinkError.invalidEncoding }
        guard comps.scheme?.lowercased() == LinkGrammar.scheme else { throw MailLinkError.wrongScheme }
        guard comps.percentEncodedUser == nil, comps.percentEncodedPassword == nil, comps.port == nil,
              comps.fragment == nil
        else { throw MailLinkError.invalidEncoding }
        guard let host = comps.percentEncodedHost?.lowercased(), !host.isEmpty else { throw MailLinkError.unknownRoute }
        let segments = try pathSegments(comps.percentEncodedPath)
        let query = try queryItems(comps.percentEncodedQuery)

        switch host {
        case "thread", "draft":
            guard segments.count == 2 else { throw MailLinkError.unknownRoute }
            let account = try accountRef(segments[0])
            let id = try validatedID(segments[1])
            return host == "thread" ? .thread(account: account, threadID: id) : .draft(account: account, draftID: id)

        case "review":
            guard segments.isEmpty else { throw MailLinkError.unknownRoute }
            let defaultAccount = try query["account"].map(accountRef)
            guard let idsText = query["ids"], !idsText.isEmpty else { throw MailLinkError.invalidID }
            let items = idsText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard items.count <= LinkGrammar.maxReviewIDs else { throw MailLinkError.tooManyItems }
            let refs: [DraftRef] = try items.map { item in
                if let colon = item.firstIndex(of: ":") {
                    let account = try accountRef(String(item[..<colon]))
                    return DraftRef(account: account, draftID: try validatedID(String(item[item.index(after: colon)...])))
                }
                guard let account = defaultAccount else { throw MailLinkError.invalidID }
                return DraftRef(account: account, draftID: try validatedID(item))
            }
            return .review(refs)

        case "search":
            guard segments.isEmpty else { throw MailLinkError.unknownRoute }
            let account = try query["account"].map(accountRef)
            return .search(query: query["q"] ?? "", account: account)

        case "compose":
            guard segments.isEmpty else { throw MailLinkError.unknownRoute }
            let account = try query["account"].map(accountRef)
            let to = try addresses(query["to"])
            let cc = try addresses(query["cc"])
            guard to.count + cc.count <= LinkGrammar.maxRecipients else { throw MailLinkError.tooManyItems }
            let subject = query["subject"].map { singleLine(stripControls($0)) }
            if let s = subject, s.count > LinkGrammar.maxSubjectCharacters { throw MailLinkError.tooLong }
            let body = query["body"].map(stripControls)
            if let b = body, b.utf8.count > LinkGrammar.maxBodyBytes { throw MailLinkError.tooLong }
            return .compose(ComposePrefill(account: account, to: to, cc: cc, subject: subject, body: body,
                                           droppedBcc: query.keys.contains("bcc")))

        case "settings":
            guard query.isEmpty else { throw MailLinkError.unknownRoute }
            switch segments.count {
            case 1:
                return .settings(.page(try settingsID(segments[0])))
            case 2 where segments == ["ai", "prompts"]:
                return .settings(.aiPrompts(promptID: nil))
            case 3 where segments[0] == "ai" && segments[1] == "prompts":
                return .settings(.aiPrompts(promptID: try settingsID(segments[2])))
            default:
                throw MailLinkError.unknownRoute
            }

        default:
            throw MailLinkError.unknownRoute
        }
    }

    static func settingsID(_ raw: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...64).contains(raw.count), raw.allSatisfy(allowed.contains), raw.contains(where: \.isLetter) else {
            throw MailLinkError.invalidID
        }
        return raw
    }

    private static func decode(_ s: Substring) throws -> String {
        guard let d = String(s).removingPercentEncoding else { throw MailLinkError.invalidEncoding }
        return d
    }

    private static func pathSegments(_ path: String) throws -> [String] {
        if path.isEmpty || path == "/" { return [] }
        guard path.hasPrefix("/") else { throw MailLinkError.unknownRoute }
        return try path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(decode)
    }

    private static func queryItems(_ query: String?) throws -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = try decode(parts[0]).lowercased()
            let value = parts.count > 1 ? try decode(parts[1]) : ""
            if result[name] == nil { result[name] = value }
        }
        return result
    }

    static func accountRef(_ raw: String) throws -> AccountRef {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@-")
        guard (1...254).contains(raw.count), raw.allSatisfy(allowed.contains),
              raw.contains(where: { $0.isLetter || $0.isNumber })
        else { throw MailLinkError.invalidID }
        return AccountRef(raw)
    }

    static func validatedID(_ raw: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard (1...64).contains(raw.count), raw.allSatisfy(allowed.contains) else { throw MailLinkError.invalidID }
        return raw
    }

    private static func addresses(_ value: String?) throws -> [String] {
        guard let value else { return [] }
        return try value.split(separator: ",").compactMap { part in
            let a = part.trimmingCharacters(in: .whitespaces)
            if a.isEmpty { return nil }
            guard isPlausibleAddress(a) else { throw MailLinkError.invalidAddress }
            return a
        }
    }

    static func isPlausibleAddress(_ a: String) -> Bool {
        guard a.utf8.count <= 254 else { return false }
        let forbidden = Set("<>()[],;:\"\\ ")
        guard !a.contains(where: { forbidden.contains($0) || $0.unicodeScalars.contains(where: isControl) })
        else { return false }
        let parts = a.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("..")
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .control
    }

    static func stripControls(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !isControl($0) }))
    }

    // Why: a subject is one header line; a line break from a link would leave a message that cannot be sent
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
    }
}
