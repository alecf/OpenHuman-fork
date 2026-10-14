// Why: strip leading/trailing C0 controls and spaces and inner tab/LF/CR like WHATWG, so they cannot hide a scheme
import Foundation

public enum URLPolicy {
    public enum Context: Sendable {
        case link, image
        case composeImage
    }

    public enum Decision: Equatable, Sendable {
        case allow(String)
        case remote(String)
        case reject
    }

    public static let inlinePartScheme = "ohcid"

    public static func classify(_ raw: String, context: Context) -> Decision {
        let value: String
        if raw.utf8.contains(where: { $0 <= 0x20 }) {
            var scalars = raw.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }[...]
            while let f = scalars.first, f.value <= 0x20 { scalars = scalars.dropFirst() }
            while let l = scalars.last, l.value <= 0x20 { scalars = scalars.dropLast() }
            value = String(String.UnicodeScalarView(scalars))
        } else {
            value = raw
        }
        guard let scheme = scheme(of: value) else { return .reject }
        let rest = value.dropFirst(scheme.count + 1)
        switch context {
        case .link:
            switch scheme {
            case "http", "https": return .allow(scheme + ":" + rest)
            case "mailto": return .allow("mailto:" + rest)
            default: return .reject
            }
        case .image, .composeImage:
            switch scheme {
            case "cid", inlinePartScheme:
                guard !rest.isEmpty else { return .reject }
                return .allow((context == .composeImage ? "cid" : inlinePartScheme) + ":" + rest)
            case "data":
                return isAllowedImageData(rest) ? .allow("data:" + rest) : .reject
            case "http", "https":
                return .remote(scheme + ":" + rest)
            default:
                return .reject
            }
        }
    }

    static func scheme(of value: String) -> String? {
        var bytes: [UInt8] = []
        for b in value.utf8 {
            if b == 58 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            let lower = (b >= 65 && b <= 90) ? b + 32 : b
            let isAlpha = lower >= 97 && lower <= 122
            let isOther = (b >= 48 && b <= 57) || b == 43 || b == 46 || b == 45
            guard isAlpha || (!bytes.isEmpty && isOther), bytes.count < 32 else { return nil }
            bytes.append(lower)
        }
        return nil
    }

    struct HTTPParts {
        var host: String
        var hasUserInfo: Bool
        var path: Substring
    }

    static func httpParts(_ url: String) -> HTTPParts? {
        let u = url.utf8
        guard let colon = u.firstIndex(of: 58) else { return nil }
        var i = u.index(after: colon)
        while i < u.endIndex, u[i] == 47 || u[i] == 92 { i = u.index(after: i) }
        let authorityStart = i
        while i < u.endIndex, u[i] != 47, u[i] != 92, u[i] != 63, u[i] != 35 { i = u.index(after: i) }
        let authority = url[authorityStart..<i]
        let pathStart = i
        while i < u.endIndex, u[i] != 63, u[i] != 35 { i = u.index(after: i) }
        let path = url[pathStart..<i]
        var hostPort = authority
        var hasUserInfo = false
        if let at = authority.lastIndex(of: "@") {
            hasUserInfo = true
            hostPort = authority[authority.index(after: at)...]
        }
        var host: Substring
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            host = hostPort[...close]
        } else if let portColon = hostPort.firstIndex(of: ":") {
            host = hostPort[..<portColon]
        } else {
            host = hostPort
        }
        while host.hasSuffix(".") { host = host.dropLast() }
        guard !host.isEmpty else { return nil }
        return HTTPParts(host: host.lowercased(), hasUserInfo: hasUserInfo, path: path)
    }

    private static func isAllowedImageData(_ rest: Substring) -> Bool {
        let lower = rest.prefix(32).lowercased()
        for type in ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"] {
            if lower.hasPrefix(type) {
                let next = lower.dropFirst(type.count).first
                return next == ";" || next == ","
            }
        }
        return false
    }
}
