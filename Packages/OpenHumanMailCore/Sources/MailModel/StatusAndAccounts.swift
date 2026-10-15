import Foundation
import OpenHumanCore

public enum ConnectivityState: Sendable, Hashable {
    case online(syncing: Bool, lastSyncAt: Date?)
    case offline(since: Date?)
    case rateLimited(until: Date?)
    case syncFailing(code: String, failures: Int, lastSyncAt: Date?)
    case needsReauth
}

public enum OAuthClientStatus: Sendable, Hashable {
    case missing
    case configured(source: OAuthClientSourceKind)
    case configuredWithoutSecret(source: OAuthClientSourceKind)
}

public enum OAuthClientSourceKind: String, Sendable, Hashable {
    case environment
    case file
}

public struct OAuthClientSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let shortID: String
    public let isDefault: Bool
    public let isSelected: Bool
    public let hasSecret: Bool

    public init(id: String, shortID: String, isDefault: Bool, isSelected: Bool, hasSecret: Bool) {
        self.id = id
        self.shortID = shortID
        self.isDefault = isDefault
        self.isSelected = isSelected
        self.hasSecret = hasSecret
    }

    public var title: String {
        "…\(shortID)" + (isDefault ? " (default)" : "") + (hasSecret ? "" : " (no secret)")
    }
}

public enum OAuthClientSync: Sendable, Hashable {
    case syncing
    case notSyncing
    case unavailable
}

public enum SignInSync: Sendable, Hashable {
    case syncing
    case pending
    case notSyncing
    case unavailable
    case ownSignInHere
    case needsSignInHere
}

public struct OAuthClientUsage: Sendable, Hashable, Identifiable {
    public let client: OAuthClientSummary
    public let importedAt: Date?
    public let sync: OAuthClientSync?
    public let accounts: [AccountID]
    public let calendars: [AccountID]

    public init(client: OAuthClientSummary, importedAt: Date?, accounts: [AccountID], calendars: [AccountID],
                sync: OAuthClientSync? = nil) {
        self.client = client
        self.importedAt = importedAt
        self.sync = sync
        self.accounts = accounts
        self.calendars = calendars
    }

    public var id: OAuthClientSummary.ID { client.id }
    public var isInUse: Bool { !accounts.isEmpty || !calendars.isEmpty }
    public var hasImportedFile: Bool { importedAt != nil || sync != nil }

    public func removalRefusal(emails: [AccountID: String]) -> String? {
        let name = "…\(client.shortID)"
        func list(_ ids: [AccountID]) -> String {
            let names = ids.map { emails[$0] ?? "an account" }
            guard names.count > 1, let last = names.last else { return names.first ?? "" }
            return names.dropLast().joined(separator: ", ") + " and " + last
        }
        if !accounts.isEmpty {
            return "\(name) is still used by \(list(accounts)). Move \(accounts.count == 1 ? "it" : "them") to another "
                + "client with Replace…, or sign \(accounts.count == 1 ? "it" : "them") out, first."
        }
        if !calendars.isEmpty {
            return "\(name) is still used by the calendar of \(list(calendars)). Connect that calendar with another "
                + "client in Settings › Calendar first."
        }
        if client.isDefault {
            return "\(name) is the default client for new sign-ins, so Mail keeps it."
        }
        if !hasImportedFile {
            return "\(name) comes from this Mac's environment, not from the Keychain, so there's nothing to remove."
        }
        return nil
    }
}

public enum OAuthClientReplacement: Sendable, Hashable {
    case sameClient
    case differentClient(id: OAuthClientSummary.ID, shortID: String)
}

public struct AccountSetupError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case cancelled
        case clientMissing
        case refused
        case invalidPaste
        case failed
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

public protocol AccountManaging: Sendable {
    func accounts() -> AsyncThrowingStream<[Account], Error>
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus>
    func importOAuthClient(json: Data) async throws
    func oauthClientImportNote() async -> String?
    func oauthClients() async -> [OAuthClientSummary]
    func selectOAuthClient(_ id: OAuthClientSummary.ID?) async throws
    func oauthClientShortID(for account: AccountID) async -> String?
    func oauthClientUsage() async -> [OAuthClientUsage]
    func removeOAuthClient(_ id: OAuthClientSummary.ID) async throws
    func inspectOAuthClientFile(_ json: Data, replacing id: OAuthClientSummary.ID) async throws -> OAuthClientReplacement
    func replaceOAuthClient(_ id: OAuthClientSummary.ID, json: Data) async throws
    func moveAccount(_ account: AccountID, toOAuthClient id: OAuthClientSummary.ID) async throws
    func setOAuthClientSync(_ id: OAuthClientSummary.ID, enabled: Bool) async throws
    func signInSync(for account: AccountID) async -> SignInSync?
    func setSignInSync(_ account: AccountID, enabled: Bool) async throws
    func signInsSyncThroughICloudKeychain() async -> Bool
    func sharedSignIns() async -> [String]
    func useSharedSignIn(email: String) async throws -> AccountID
    func addAccount(loginHint: String?) async throws -> AccountID
    func reauthorize(_ account: AccountID) async throws
    func remove(_ account: AccountID) async throws
    func removeIncludingSharedSignIn(_ account: AccountID) async throws
    func setAlias(_ account: AccountID, _ alias: String?) async throws
    func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge
    func completeRemoteSignIn(pasted: String) async throws -> AccountID
    func cancelRemoteSignIn() async
}

public struct RemoteSignInChallenge: Sendable, Equatable {
    public let url: URL
    public let expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

extension AccountManaging {
    public func beginRemoteSignIn(loginHint: String?) async throws -> RemoteSignInChallenge {
        throw AccountSetupError(.failed, "Signing in from another device isn't available here.")
    }

    public func completeRemoteSignIn(pasted: String) async throws -> AccountID {
        throw AccountSetupError(.failed, "Signing in from another device isn't available here.")
    }

    public func cancelRemoteSignIn() async {}
}

extension AccountManaging {
    public func oauthClients() async -> [OAuthClientSummary] { [] }

    public func selectOAuthClient(_ id: OAuthClientSummary.ID?) async throws {
        throw AccountSetupError(.failed, "Choosing a sign-in client isn't available here.")
    }

    public func oauthClientShortID(for account: AccountID) async -> String? { nil }

    public func oauthClientUsage() async -> [OAuthClientUsage] { [] }

    public func oauthClientImportNote() async -> String? { nil }

    public func removeOAuthClient(_ id: OAuthClientSummary.ID) async throws {
        throw AccountSetupError(.failed, "Removing a sign-in client isn't available here.")
    }

    public func inspectOAuthClientFile(_ json: Data, replacing id: OAuthClientSummary.ID) async throws
        -> OAuthClientReplacement {
        throw AccountSetupError(.failed, "Replacing a sign-in client isn't available here.")
    }

    public func replaceOAuthClient(_ id: OAuthClientSummary.ID, json: Data) async throws {
        throw AccountSetupError(.failed, "Replacing a sign-in client isn't available here.")
    }

    public func moveAccount(_ account: AccountID, toOAuthClient id: OAuthClientSummary.ID) async throws {
        throw AccountSetupError(.failed, "Moving an account to another sign-in client isn't available here.")
    }

    public func setOAuthClientSync(_ id: OAuthClientSummary.ID, enabled: Bool) async throws {
        throw AccountSetupError(.failed, "Choosing whether a sign-in client syncs isn't available here.")
    }

    public func signInSync(for account: AccountID) async -> SignInSync? { nil }

    public func setSignInSync(_ account: AccountID, enabled: Bool) async throws {
        throw AccountSetupError(.failed, "Choosing whether a sign-in syncs isn't available here.")
    }

    public func signInsSyncThroughICloudKeychain() async -> Bool { false }

    public func sharedSignIns() async -> [String] { [] }

    public func useSharedSignIn(email: String) async throws -> AccountID {
        throw AccountSetupError(.failed, "Using a sign-in from another device isn't available here.")
    }
}

extension AccountManaging {
    public func accounts() -> AsyncThrowingStream<[Account], Error> { unsupportedStream("AccountManaging.accounts") }
    public func reauthorize(_ account: AccountID) async throws { throw MailPortError.unsupported("reauthorize") }
    public func remove(_ account: AccountID) async throws { throw MailPortError.unsupported("remove") }
    public func removeIncludingSharedSignIn(_ account: AccountID) async throws {
        throw MailPortError.unsupported("removeIncludingSharedSignIn")
    }
    public func setAlias(_ account: AccountID, _ alias: String?) async throws {
        throw MailPortError.unsupported("setAlias")
    }
}
