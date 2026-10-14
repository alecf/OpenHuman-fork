import Foundation
import OpenHumanCore

extension OAuthClientConfig {
    public var hasClientSecret: Bool { !(clientSecret ?? "").isEmpty }

    public static let environmentKey = "OPENHUMAN_OAUTH_CLIENT_JSON"
    public static let storeFileName = "oauth-client.json"

    static let defaultAuthURI = URL(string: "https://accounts.google.com/o/oauth2/auth")!
    static let defaultTokenURI = URL(string: "https://oauth2.googleapis.com/token")!
    static let googleOAuthHosts: Set<String> = ["accounts.google.com", "oauth2.googleapis.com"]

    public static func load(environment: [String: String], storeDirectory: URL?) throws -> OAuthClientConfig {
        switch resolveSource(environment: environment, storeDirectory: storeDirectory) {
        case .environment:
            let path = environmentPath(environment)!
            guard let data = FileManager.default.contents(atPath: path) else {
                throw OAuthError.configurationMissing("\(environmentKey): file not readable")
            }
            return try parseGoogleJSON(data, source: environmentKey)
        case .storeFile:
            return try readClientFile(storeFileURL(storeDirectory!), label: storeFileName)
        case .missing:
            throw OAuthError.configurationMissing(
                "no OAuth client: set \(environmentKey), import a Desktop client JSON, or use the client picker")
        }
    }

    public static func resolveSource(environment: [String: String], storeDirectory: URL?) -> OAuthClientSource {
        if environmentPath(environment) != nil { return .environment }
        if let storeDirectory, SecureFile.inspect(storeFileURL(storeDirectory)).kind != .missing { return .storeFile }
        return .missing
    }

    public static func importGoogleJSON(_ data: Data, storeDirectory: URL) throws -> OAuthClientConfig {
        let config = try parseGoogleJSON(data, source: "import")
        do {
            try SecureFile.ensureDirectory(storeDirectory, mode: 0o700, tighten: false)
            try SecureFile.writeAtomically(try config.normalizedGoogleJSON(), to: storeFileURL(storeDirectory), mode: 0o600)
        } catch let failure as SecureFile.Failure {
            throw OAuthError.configurationMissing("import: could not write \(storeFileName) (\(failure.description))")
        }
        Log(.oauth).notice("OAuth client imported into \(storeFileName)")
        return config
    }

    static func storeFileURL(_ storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent(storeFileName, isDirectory: false)
    }

    static func readClientFile(_ url: URL, label: String) throws -> OAuthClientConfig {
        let (kind, mode) = SecureFile.inspect(url)
        guard kind == .regularFile else {
            throw OAuthError.configurationMissing("\(label): not a regular file")
        }
        if (mode & 0o077) != 0 {
            if chmod(url.path, 0o600) == 0 {
                Log(.oauth).notice("\(label): mode \(String(mode, radix: 8)) was looser than 0600; tightened")
            } else {
                throw OAuthError.configurationMissing("\(label): mode is looser than 0600 and chmod failed")
            }
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw OAuthError.configurationMissing("\(label): file not readable")
        }
        return try parseGoogleJSON(data, source: label)
    }

    private static func environmentPath(_ environment: [String: String]) -> String? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    // Endpoints from the file are refused unless Google's: those URLs receive the code, PKCE verifier, secret and refresh tokens
    static func parseGoogleJSON(_ data: Data, source: String) throws -> OAuthClientConfig {
        func malformed(_ why: String) -> OAuthError { .configurationMissing("\(source): \(why)") }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw malformed("not a JSON object")
        }
        let fields: [String: Any]
        if let installed = root["installed"] {
            guard let dict = installed as? [String: Any] else { throw malformed("\"installed\" is not an object") }
            fields = dict
        } else if let web = root["web"] {
            guard let dict = web as? [String: Any] else { throw malformed("\"web\" is not an object") }
            fields = dict
        } else if root["client_id"] != nil {
            fields = root
        } else {
            throw malformed("expected Google's Desktop client JSON (\"installed\")")
        }
        guard let clientID = fields["client_id"] as? String,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw malformed("client_id missing or empty")
        }
        var secret: String?
        if let value = fields["client_secret"] {
            guard let string = value as? String else { throw malformed("client_secret is not a string") }
            secret = string.isEmpty ? nil : string
        }
        func endpoint(_ key: String, google: URL) throws -> URL {
            guard let value = fields[key] else { return google }
            guard let string = value as? String, let url = URL(string: string),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw malformed("\(key) must be an https URL")
            }
            guard let host = url.host?.lowercased(), googleOAuthHosts.contains(host), url.port == nil,
                  url.user == nil, url.password == nil else {
                Log(.oauth).error("\(source): \(key) is not a Google endpoint; the client JSON is refused")
                throw malformed("\(key) is not Google's sign-in address. Mail only signs in at Google, so a file "
                    + "that sends sign-in elsewhere is refused. Download the client JSON again from Google Cloud "
                    + "Console")
            }
            return google
        }
        return OAuthClientConfig(clientID: clientID, clientSecret: secret,
                                 authURI: try endpoint("auth_uri", google: defaultAuthURI),
                                 tokenURI: try endpoint("token_uri", google: defaultTokenURI))
    }

    func normalizedGoogleJSON() throws -> Data {
        var installed: [String: String] = [
            "client_id": clientID,
            "auth_uri": authURI.absoluteString,
            "token_uri": tokenURI.absoluteString,
        ]
        if let clientSecret { installed["client_secret"] = clientSecret }
        return try JSONSerialization.data(withJSONObject: ["installed": installed], options: [.sortedKeys, .prettyPrinted])
    }
}

extension OAuthClientConfig: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OAuthClientConfig(clientID: <redacted>, clientSecret: \(clientSecret == nil ? "nil" : "<redacted>"), "
            + "authURI: \(authURI.absoluteString), tokenURI: \(tokenURI.absoluteString))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}

extension StoredToken: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "StoredToken(refreshToken: <redacted>, accessToken: \(accessToken == nil ? "nil" : "<redacted>"), "
            + "accessTokenExpiry: \(accessTokenExpiry.map { "\($0.timeIntervalSince1970)" } ?? "nil"), "
            + "grantedScopes: \(grantedScopes), clientID: <redacted>)"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["redacted": description]) }
}
