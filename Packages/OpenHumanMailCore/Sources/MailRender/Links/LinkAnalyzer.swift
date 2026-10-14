import Foundation

public struct SuspiciousLink: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable, CaseIterable {
        case domainMismatch
        case addressMismatch
        case credentialsInURL
        case ipAddressHost
        case punycodeHost
    }

    public let href: String
    public let displayText: String
    public let displayedDestination: String?
    public let actualDestination: String
    public let actualHost: String?
    public let reasons: [Reason]

    public func matches(_ url: URL) -> Bool {
        LinkAnalyzer.matchKey(url.absoluteString) == LinkAnalyzer.matchKey(href)
    }
}

public enum LinkAnalyzer {
    public static func check(href: String, displayText rawText: String) -> SuspiciousLink? {
        let couldNameTarget = rawText.utf8.contains { $0 == 46 || $0 == 64 } || rawText.utf8.contains { $0 >= 0xE2 }
        let text = couldNameTarget ? cleanedDisplayText(rawText) : ""
        var reasons: [SuspiciousLink.Reason] = []
        var displayed: String?
        let actual: String
        var actualHost: String?

        if let first = href.utf8.first, first | 0x20 == 109, href.utf8.count >= 7, href.prefix(7).lowercased() == "mailto:" {
            guard let address = mailtoAddress(href) else { return nil }
            actual = address
            let actualDomain = address.split(separator: "@").last.map(String.init).flatMap(RegistrableDomain.of)
            switch couldNameTarget ? displayedTarget(in: text) : nil {
            case .address(let shown)?:
                if shown != address { reasons.append(.addressMismatch); displayed = shown }
            case .host(let host)?:
                let shown = RegistrableDomain.of(host)
                if shown != actualDomain { reasons.append(.domainMismatch); displayed = shown }
            case nil:
                break
            }
        } else {
            guard let parts = URLPolicy.httpParts(href) else { return nil }
            let host = parts.host
            if parts.hasUserInfo { reasons.append(.credentialsInURL) }
            if host.hasPrefix("[") || (host.utf8.last.map { $0 >= 48 && $0 <= 57 } ?? false && RegistrableDomain.isIPv4(host)) {
                reasons.append(.ipAddressHost)
            }
            if host.hasPrefix("xn--") || host.contains(".xn--") { reasons.append(.punycodeHost) }
            let shown = couldNameTarget ? displayedTarget(in: text) : nil
            guard shown != nil || !reasons.isEmpty else { return nil }
            actualHost = host
            let actualDomain = RegistrableDomain.of(host) ?? host
            actual = actualDomain
            switch shown {
            case .host(let shownHost)?:
                let shown = RegistrableDomain.of(shownHost)
                if shown != actualDomain { reasons.insert(.domainMismatch, at: 0); displayed = shown }
            case .address(let shownAddress)?:
                let shown = shownAddress.split(separator: "@").last.map(String.init).flatMap(RegistrableDomain.of)
                if shown != actualDomain { reasons.insert(.domainMismatch, at: 0); displayed = shown }
            case nil:
                break
            }
        }
        guard !reasons.isEmpty else { return nil }
        return SuspiciousLink(href: href, displayText: String(text.prefix(200)), displayedDestination: displayed,
                              actualDestination: actual, actualHost: actualHost, reasons: reasons)
    }

    enum Displayed: Equatable {
        case host(String)
        case address(String)
    }

    static func displayedTarget(in text: String) -> Displayed? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: Set<Character> = ["<", ">", "(", ")", "[", "]", "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        while let f = t.first, wrappers.contains(f) { t.removeFirst() }
        while let l = t.last, wrappers.contains(l) || l == "." || l == "," || l == ";" || l == ":" { t.removeLast() }
        guard !t.isEmpty, t.count <= 2048, !t.contains(where: \.isWhitespace) else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("mailto:") { t = String(t.dropFirst(7)) }
        if !lower.hasPrefix("http://"), !lower.hasPrefix("https://"), t.contains("@"), !t.contains("/") {
            let parts = t.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let host = hostLike(String(parts[1])) else { return nil }
            return .address(String(parts[0]).lowercased() + "@" + host)
        }
        var rest = Substring(t)
        if lower.hasPrefix("http://") { rest = rest.dropFirst(7) } else if lower.hasPrefix("https://") { rest = rest.dropFirst(8) } else if lower.hasPrefix("//") { rest = rest.dropFirst(2) }
        let hostPart = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        var hostText = String(hostPart)
        if let at = hostText.lastIndex(of: "@") { hostText = String(hostText[hostText.index(after: at)...]) }
        if let colon = hostText.lastIndex(of: ":"), hostText[hostText.index(after: colon)...].allSatisfy(\.isNumber) {
            hostText = String(hostText[..<colon])
        }
        guard let host = hostLike(hostText) else { return nil }
        let explicit = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
            || rest.count > hostPart.count
        if !explicit, let tld = host.split(separator: ".").last, fileExtensions.contains(String(tld)) { return nil }
        return .host(host)
    }

    static func hostLike(_ raw: String) -> String? {
        var h = raw.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if RegistrableDomain.isIPv4(h) { return h }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }) else { return nil }
        let tld = labels.last!
        guard tld.count >= 2, tld.hasPrefix("xn--") || tld.allSatisfy(\.isLetter) else { return nil }
        return h
    }

    static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "jpg", "jpeg", "png", "gif", "webp", "heic",
        "html", "htm", "json", "xml", "js", "ts", "swift", "md", "rtf", "mp3", "mp4", "wav", "key", "pages", "numbers",
        "ics", "eml", "vcf", "tif", "tiff", "bmp", "svg", "psd", "ai", "eps", "gz", "tar", "rar", "dmg", "pkg", "exe",
        "msg", "odt", "ods", "odp", "epub", "aac", "m4a", "avi", "mkv", "py", "rb", "java", "cpp", "yaml", "yml",
    ]

    static func cleanedDisplayText(_ text: String) -> String {
        let removed: Set<UInt32> = [0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D,
                                    0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]
        let dots: Set<UInt32> = [0x3002, 0xFF0E, 0xFF61]
        let kept = text.unicodeScalars.filter { !removed.contains($0.value) }.map { dots.contains($0.value) ? "." : $0 }
        let s = String(String.UnicodeScalarView(kept))
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func mailtoAddress(_ href: String) -> String? {
        let body = href.dropFirst("mailto:".count)
        let path = body.prefix { $0 != "?" }
        let first = path.split(separator: ",").first.map(String.init) ?? ""
        let decoded = (first.removingPercentEncoding ?? first).trimmingCharacters(in: .whitespaces).lowercased()
        let parts = decoded.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let host = hostLike(String(parts[1])) else { return nil }
        return String(parts[0]) + "@" + host
    }

    static func percentEncodedLoosely(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func matchKey(_ s: String) -> String {
        guard let c = URLComponents(string: s) ?? URLComponents(string: percentEncodedLoosely(s)),
              let scheme = c.scheme?.lowercased() else { return s.lowercased() }
        if scheme == "mailto" {
            return "mailto:" + (c.path.removingPercentEncoding ?? c.path).lowercased() + "?" + (c.query ?? "")
        }
        var key = scheme + "://" + (c.host?.lowercased() ?? "")
        if let port = c.port, !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) { key += ":\(port)" }
        let path = c.path.isEmpty ? "/" : c.path
        key += path
        if let q = c.query, !q.isEmpty { key += "?" + q }
        return key
    }
}
