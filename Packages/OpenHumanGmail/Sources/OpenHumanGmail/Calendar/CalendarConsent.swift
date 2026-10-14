import Foundation
import OpenHumanCore

public struct CalendarConsent: Sendable {
    public let flow: OAuthFlow

    public init(client: OAuthClientConfig, mode: SafeMode, transport: any HTTPTransport,
                receiver: any LoopbackRedirectReceiver, browser: any ExternalBrowser, clock: any OHClock) {
        flow = OAuthFlow(client: client, scopes: CalendarScopes.requested(for: mode), transport: transport,
                         receiver: receiver, browser: browser, clock: clock)
    }

    public var scopes: [String] { flow.scopes }

    public func authorize(account: String, timeout: Duration) async throws -> StoredToken {
        let requested = scopes
        let token = try await flow.authorizeGrant(loginHint: account, timeout: timeout) { granted in
            try CalendarScopes.check(granted: granted, requested: requested)
        }
        Log(.oauth).notice("calendar consent complete (\(token.grantedScopes.count) scopes)")
        return token
    }
}
