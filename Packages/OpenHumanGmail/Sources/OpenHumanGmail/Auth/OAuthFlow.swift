import Foundation
import OpenHumanCore

public struct OAuthFlow: Sendable {
    public let client: OAuthClientConfig
    public let scopes: [String]
    let transport: any HTTPTransport
    let receiver: any LoopbackRedirectReceiver
    let browser: any ExternalBrowser
    let clock: any OHClock
    let randomBytes: @Sendable (Int) -> Data

    public static let successHTML = """
        <!doctype html><html><head><meta charset="utf-8"><title>OpenHuman Mail</title></head>\
        <body style="font-family:-apple-system,sans-serif;margin:3em"><p>You can close this tab and return to \
        OpenHuman Mail.</p></body></html>
        """

    static let profileURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!

    public init(client: OAuthClientConfig, scopes: [String], transport: any HTTPTransport,
                receiver: any LoopbackRedirectReceiver, browser: any ExternalBrowser, clock: any OHClock) {
        self.init(client: client, scopes: scopes, transport: transport, receiver: receiver, browser: browser,
                  clock: clock, randomBytes: OAuthRandom.bytes)
    }

    public init(client: OAuthClientConfig, mode: SafeMode, transport: any HTTPTransport,
                receiver: any LoopbackRedirectReceiver, browser: any ExternalBrowser, clock: any OHClock) {
        self.init(client: client, scopes: mode.oauthScopes, transport: transport, receiver: receiver,
                  browser: browser, clock: clock)
    }

    init(client: OAuthClientConfig, scopes: [String], transport: any HTTPTransport,
         receiver: any LoopbackRedirectReceiver, browser: any ExternalBrowser, clock: any OHClock,
         randomBytes: @escaping @Sendable (Int) -> Data) {
        self.client = client
        self.scopes = scopes
        self.transport = transport
        self.receiver = receiver
        self.browser = browser
        self.clock = clock
        self.randomBytes = randomBytes
    }

    public var isReadOnlyProfile: Bool { !OAuthScopes.carriesMailWrite(scopes) }

    public var toleratedExtraScopes: Set<String> {
        scopes.contains(GmailScope.modify) ? OAuthScopes.identity.union([GmailScope.readonly]) : OAuthScopes.identity
    }

    public func authorize(loginHint: String?, timeout: Duration) async throws -> OAuthResult {
        let redirectURI = try await receiver.start()
        let pkce = PKCE.generate(randomBytes: randomBytes)
        let state = OAuthRandom.state(randomBytes: randomBytes)
        let callback: URLComponents
        do {
            await receiver.expectState(state)
            let url = authorizationURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state,
                                       loginHint: loginHint)
            try await browser.open(url)
            callback = try await waitForCallback(timeout: timeout)
        } catch {
            await receiver.stop()
            throw Self.normalize(error)
        }
        await receiver.stop()
        return try await complete(callback: callback, expectedPath: redirectURI.path, verifier: pkce.verifier,
                                  expectedState: state, redirectURI: redirectURI)
    }

    public func authorizeGrant(loginHint: String?, timeout: Duration,
                               accept: ([String]) throws -> Void) async throws -> StoredToken {
        let redirectURI = try await receiver.start()
        let pkce = PKCE.generate(randomBytes: randomBytes)
        let state = OAuthRandom.state(randomBytes: randomBytes)
        let callback: URLComponents
        do {
            await receiver.expectState(state)
            let url = authorizationURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state,
                                       loginHint: loginHint)
            try await browser.open(url)
            callback = try await waitForCallback(timeout: timeout)
        } catch {
            await receiver.stop()
            throw Self.normalize(error)
        }
        await receiver.stop()
        let code = try Self.validate(callback: callback, expectedPath: redirectURI.path, expectedState: state)
        let reply = try await TokenEndpoint.post(
            form: [
                ("code", code), ("code_verifier", pkce.verifier), ("client_id", client.clientID),
            ] + (client.clientSecret.map { [("client_secret", $0)] } ?? []) + [
                ("redirect_uri", redirectURI.absoluteString), ("grant_type", "authorization_code"),
            ],
            to: client.tokenURI, transport: transport, clock: clock, retryWaits: [])
        guard reply.status == 200, let body = reply.body else { throw TokenEndpoint.failure(reply) }
        guard let accessToken = body.accessToken, !accessToken.isEmpty else {
            throw OAuthError.tokenEndpoint(status: reply.status, error: "missing_access_token", description: nil)
        }
        guard let refreshToken = body.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.tokenEndpoint(status: reply.status, error: "missing_refresh_token", description: nil)
        }
        let granted = body.grantedScopes
        try accept(granted)
        let expiry = clock.now.addingTimeInterval(TimeInterval(body.expiresIn ?? 3600))
        Log(.oauth).info("grant complete; scopes \(granted.joined(separator: " "))")
        return StoredToken(refreshToken: refreshToken, accessToken: accessToken, accessTokenExpiry: expiry,
                           grantedScopes: granted, clientID: client.clientID)
    }

    public struct ManualAuthorization: Sendable, Equatable, CustomStringConvertible {
        public let url: URL
        public let verifier: String
        public let state: String
        public let redirectURI: URL

        public var description: String {
            "ManualAuthorization(url: <consent URL>, verifier: <redacted>, state: <redacted>, "
                + "redirectURI: \(redirectURI.absoluteString))"
        }
    }

    public static func manualRedirectURI(port: UInt16? = nil) -> URL {
        let chosen = port ?? UInt16.random(in: 49152...65535)
        return URL(string: "http://127.0.0.1:\(chosen)/oauth2callback")!
    }

    public func beginManual(redirectURI: URL = OAuthFlow.manualRedirectURI(),
                            loginHint: String? = nil) throws -> ManualAuthorization {
        guard Self.isLoopbackRedirect(redirectURI) else { throw OAuthError.denied("invalid_redirect_uri") }
        let pkce = PKCE.generate(randomBytes: randomBytes)
        let state = OAuthRandom.state(randomBytes: randomBytes)
        let url = authorizationURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state,
                                   loginHint: loginHint)
        return ManualAuthorization(url: url, verifier: pkce.verifier, state: state, redirectURI: redirectURI)
    }

    public func manualAuthorizationURL(redirectURI: URL) -> (url: URL, verifier: String, state: String) {
        let pkce = PKCE.generate(randomBytes: randomBytes)
        let state = OAuthRandom.state(randomBytes: randomBytes)
        let url = authorizationURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state, loginHint: nil)
        return (url, pkce.verifier, state)
    }

    public func completeManual(pasted text: String, _ session: ManualAuthorization) async throws -> OAuthResult {
        try await completeManual(pastedURL: Self.parsePasted(text), verifier: session.verifier, state: session.state,
                                 redirectURI: session.redirectURI)
    }

    public func completeManual(pastedURL: URL, verifier: String, state: String,
                               redirectURI: URL) async throws -> OAuthResult {
        guard Self.isLoopbackRedirect(redirectURI) else { throw OAuthError.denied("invalid_redirect_uri") }
        guard let components = URLComponents(url: pastedURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.denied("invalid_callback")
        }
        guard Self.matchesRedirect(components, redirectURI) else { throw OAuthError.denied("redirect_mismatch") }
        return try await complete(callback: components, expectedPath: redirectURI.path, verifier: verifier,
                                  expectedState: state, redirectURI: redirectURI)
    }

    func authorizationURL(redirectURI: URL, challenge: String, state: String, loginHint: String?) -> URL {
        var components = URLComponents(url: client.authURI, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        // URLComponents leaves "+" unescaped in query values, and Google would read it as a space
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func waitForCallback(timeout: Duration) async throws -> URLComponents {
        let receiver = self.receiver, clock = self.clock
        return try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask { try await receiver.waitForCallback(timeout: timeout, successHTML: Self.successHTML) }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthError.cancelled }
            return first
        }
    }

    func complete(callback: URLComponents, expectedPath: String, verifier: String, expectedState: String,
                  redirectURI: URL) async throws -> OAuthResult {
        let code = try Self.validate(callback: callback, expectedPath: expectedPath, expectedState: expectedState)
        let reply = try await TokenEndpoint.post(
            form: [
                ("code", code), ("code_verifier", verifier), ("client_id", client.clientID),
            ] + (client.clientSecret.map { [("client_secret", $0)] } ?? []) + [
                ("redirect_uri", redirectURI.absoluteString), ("grant_type", "authorization_code"),
            ],
            to: client.tokenURI, transport: transport, clock: clock, retryWaits: [])
        guard reply.status == 200, let body = reply.body else { throw TokenEndpoint.failure(reply) }
        guard let accessToken = body.accessToken, !accessToken.isEmpty else {
            throw OAuthError.tokenEndpoint(status: reply.status, error: "missing_access_token", description: nil)
        }
        guard let refreshToken = body.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.tokenEndpoint(status: reply.status, error: "missing_refresh_token", description: nil)
        }
        let granted = body.grantedScopes
        try checkGrantedScopes(granted)
        let profile = try await fetchProfile(accessToken: accessToken)
        let email = AccountCredentials.accountKey(profile.emailAddress)
        guard !email.isEmpty else { throw GmailError.decoding("GmailProfile") }
        let expiry = clock.now.addingTimeInterval(TimeInterval(body.expiresIn ?? 3600))
        let token = StoredToken(refreshToken: refreshToken, accessToken: accessToken, accessTokenExpiry: expiry,
                                grantedScopes: granted, clientID: client.clientID)
        Log(.oauth).info("authorization complete; scopes \(granted.joined(separator: " "))")
        return OAuthResult(email: email, token: token, profile: profile)
    }

    // Repeated parameters are refused: a reader taking the first and one taking the last would disagree
    static func validate(callback: URLComponents, expectedPath: String, expectedState: String) throws -> String {
        guard callback.path == expectedPath else { throw OAuthError.denied("invalid_callback") }
        let items = callback.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.map { $0.value ?? "" } }
        let states = values("state")
        guard states.count == 1, constantTimeEquals(states[0], expectedState) else { throw OAuthError.stateMismatch }
        let errors = values("error"), codes = values("code")
        guard errors.count <= 1, codes.count <= 1 else { throw OAuthError.denied("invalid_callback") }
        if let error = errors.first { throw OAuthError.denied(isErrorCode(error) ? error : "invalid_callback") }
        guard let code = codes.first, !code.isEmpty else { throw OAuthError.denied("missing_code") }
        return code
    }

    static func isErrorCode(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || $0 == 0x5F }
    }

    static func isLoopbackRedirect(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "http",
              c.host == "127.0.0.1", let port = c.port, (1...65535).contains(port), c.path.hasPrefix("/"),
              c.path.count > 1, c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return false }
        return true
    }

    static func matchesRedirect(_ pasted: URLComponents, _ redirectURI: URL) -> Bool {
        guard let expected = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false) else { return false }
        return pasted.scheme?.lowercased() == "http" && pasted.host == expected.host && pasted.port == expected.port
            && pasted.path == expected.path && pasted.user == nil && pasted.password == nil && pasted.fragment == nil
    }

    static func parsePasted(_ text: String) throws -> URL {
        let wrappers = CharacterSet(charactersIn: "\"'`<>()[]{}\u{201C}\u{201D}\u{2018}\u{2019}")
        let trailing = wrappers.union(CharacterSet(charactersIn: ".,;"))
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        var s = tokens.first(where: { $0.contains("127.0.0.1") }) ?? tokens.first ?? ""
        s = s.trimmingCharacters(in: wrappers)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        s = s.trimmingCharacters(in: trailing)
        if s.hasPrefix("127.0.0.1:") { s = "http://" + s }
        guard s.contains("?"), s.contains("://"), let url = URL(string: s) else {
            throw OAuthError.denied("manual_paste_not_a_redirect_url")
        }
        return url
    }

    func checkGrantedScopes(_ granted: [String]) throws {
        let missing = OAuthScopes.missing(scopes, in: granted)
        if !missing.isEmpty { throw OAuthError.insufficientScopes(missing: missing) }
        let extra = Set(OAuthScopes.extra(granted, beyond: scopes)).subtracting(toleratedExtraScopes).sorted()
        guard extra.isEmpty else {
            if isReadOnlyProfile {
                Log(.oauth).error("read-only sign-in refused: Google granted extra scopes \(extra)")
                throw OAuthError.denied("read-only sign-in refused: token carries scopes beyond gmail.readonly")
            }
            Log(.oauth).error("write sign-in refused: Google granted extra scopes \(extra)")
            throw OAuthError.denied("write sign-in refused: token carries scopes beyond gmail.modify")
        }
    }

    private func fetchProfile(accessToken: String) async throws -> GmailProfile {
        let request = HTTPRequest(method: "GET", url: Self.profileURL,
                                  headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"])
        let response = try await apiTransport.send(request)
        switch response.status {
        case 200:
            do { return try JSONDecoder().decode(GmailProfile.self, from: response.body) } catch {
                throw GmailError.decoding("GmailProfile")
            }
        case 401: throw GmailError.unauthorized
        case 403: throw GmailError.forbidden(reason: Self.errorReason(response.body) ?? "forbidden", message: "users.getProfile")
        default: throw GmailError.server(status: response.status, message: "users.getProfile")
        }
    }

    var apiTransport: any HTTPTransport { ReadOnlyTransport(wrapping: transport) }

    private static func errorReason(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        if let errors = error["errors"] as? [[String: Any]], let reason = errors.first?["reason"] as? String { return reason }
        return error["status"] as? String
    }

    private static func normalize(_ error: Error) -> Error {
        if error is CancellationError { return OAuthError.cancelled }
        return error
    }
}
