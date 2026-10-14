import Foundation
import OpenHumanCore

public struct StoredToken: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var accessToken: String?
    public var accessTokenExpiry: Date?
    public var grantedScopes: [String]
    public var clientID: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        refreshToken: String,
        accessToken: String? = nil,
        accessTokenExpiry: Date? = nil,
        grantedScopes: [String],
        clientID: String
    ) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.grantedScopes = grantedScopes
        self.clientID = clientID
    }
    // end generated-init
}

public protocol TokenStore: Sendable {
    func load(account email: String) throws -> StoredToken?
    func save(_ token: StoredToken, account email: String) throws
    func delete(account email: String) throws
    func allAccounts() throws -> [String]
}

public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public struct OAuthClientConfig: Codable, Sendable {
    public var clientID: String; public var clientSecret: String?
    public var authURI: URL; public var tokenURI: URL

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        clientID: String,
        clientSecret: String? = nil,
        authURI: URL,
        tokenURI: URL
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authURI = authURI
        self.tokenURI = tokenURI
    }
    // end generated-init
}

public enum OAuthClientSource: Equatable, Sendable {
    case missing
    case environment, storeFile
}

public protocol LoopbackRedirectReceiver: Sendable {
    func start() async throws -> URL
    func expectState(_ state: String) async
    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents
    func stop() async
}

extension LoopbackRedirectReceiver {
    public func expectState(_ state: String) async {}
}

public protocol ExternalBrowser: Sendable {
    func open(_ url: URL) async throws
}

public struct OAuthResult: Sendable {
    public var email: String; public var token: StoredToken; public var profile: GmailProfile

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        email: String,
        token: StoredToken,
        profile: GmailProfile
    ) {
        self.email = email
        self.token = token
        self.profile = profile
    }
    // end generated-init
}

public enum OAuthError: Error, Equatable, Sendable {
    case stateMismatch, timedOut, cancelled
    case denied(String)
    case insufficientScopes(missing: [String])
    case reauthRequired
    case tokenEndpoint(status: Int, error: String?, description: String?)
    case configurationMissing(String)
}
