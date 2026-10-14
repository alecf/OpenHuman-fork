import Foundation

public enum GoogleConsentLink {
    public static func isValid(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: OAuthClientConfig.defaultAuthURI, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == expected.host,
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.path == expected.path, parts.fragment == nil else { return false }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? {
            let found = items.filter { $0.name == name }
            return found.count == 1 ? found[0].value : nil
        }
        guard let redirect = value("redirect_uri").flatMap(URL.init(string:)), OAuthFlow.isLoopbackRedirect(redirect),
              value("client_id")?.isEmpty == false, value("state")?.isEmpty == false,
              value("code_challenge")?.isEmpty == false, value("code_challenge_method") == PKCE.method else {
            return false
        }
        return value("include_granted_scopes") == nil
    }

    public static func redirectURI(_ url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    public static func loginHint(_ url: URL) -> String? {
        let hint = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "login_hint" }?.value
        return hint?.isEmpty == false ? hint : nil
    }

    public static func isCalendarConsent(_ url: URL) -> Bool {
        let scopes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "scope" }?.value?.split(separator: " ").map(String.init) ?? []
        return !scopes.isEmpty && scopes.allSatisfy { CalendarScopes.all.contains($0) || OAuthScopes.identity.contains($0) }
    }
}
