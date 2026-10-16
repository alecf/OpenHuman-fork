import Foundation
import OpenHumanCore

public enum CredentialIntakeState: Sendable, Equatable {
    case ready(accounts: [String], clientMissing: [String])
    case unavailable(CredentialOutcome)
}

public enum CredentialIntakeResult: Sendable, Equatable {
    case added(scopes: [String])
    case failed(CredentialOutcome)
}

public protocol CredentialIntake: Sendable {
    var source: CredentialSource { get }
    func check() async -> CredentialIntakeState
    func take(account email: String) async -> CredentialIntakeResult
}

public struct CredentialIntakeList: Sendable {
    public let providers: [any CredentialIntake]

    public init(_ providers: [any CredentialIntake]) {
        var seen = Set<CredentialSource>()
        let unique = providers.filter { seen.insert($0.source).inserted }
        let order = CredentialSource.rungOrder
        func rank(_ source: CredentialSource) -> Int { order.firstIndex(of: source) ?? order.count }
        self.providers = unique.enumerated()
            .sorted { (rank($0.element.source), $0.offset) < (rank($1.element.source), $1.offset) }
            .map(\.element)
    }

    public var sources: [CredentialSource] { providers.map(\.source) }

    public func provider(_ source: CredentialSource) -> (any CredentialIntake)? {
        providers.first { $0.source == source }
    }
}

public final class SharedSignInIntake: CredentialIntake {
    public let source = CredentialSource.shared
    private let tokens: SyncedTokenStore
    private let clients: @Sendable () -> [OAuthClientConfig]
    private let transport: any HTTPTransport
    private let clock: any OHClock
    private let retryWaits: [Duration]
    private let log: CredentialChainLog

    public convenience init(tokens: SyncedTokenStore, clients: @escaping @Sendable () -> [OAuthClientConfig],
                            transport: any HTTPTransport, clock: any OHClock, log: CredentialChainLog = .shared) {
        self.init(tokens: tokens, clients: clients, transport: transport, clock: clock,
                  retryWaits: TokenEndpoint.refreshRetryWaits, log: log)
    }

    init(tokens: SyncedTokenStore, clients: @escaping @Sendable () -> [OAuthClientConfig], transport: any HTTPTransport,
         clock: any OHClock, retryWaits: [Duration], log: CredentialChainLog) {
        self.tokens = tokens
        self.clients = clients
        self.transport = transport
        self.clock = clock
        self.retryWaits = retryWaits
        self.log = log
    }

    public func check() async -> CredentialIntakeState {
        guard tokens.shared.canHoldSharedCopies else { return unavailable(.noEntitlement) }
        let listed: [String]
        let accounts: [String]
        do {
            listed = try tokens.shared.allAccounts()
            accounts = try listed.isEmpty ? [] : tokens.sharedSignIns()
        } catch { return unavailable(Self.outcome(error)) }
        guard tokens.shared.canHoldSharedCopies else { return unavailable(.noEntitlement) }
        guard !listed.isEmpty else { return unavailable(.noItem) }
        guard !accounts.isEmpty else {
            let kept = listed.allSatisfy { (try? tokens.device.load(account: $0))?.choice != nil }
            return unavailable(kept ? .keptLocal : .refusedHere)
        }
        log.record(.readSignIn, .ok)
        let known = Set(clients().map(\.clientID))
        var ready: [String] = []
        var missing: [String] = []
        for account in accounts {
            if let id = (try? tokens.load(account: account))?.clientID, known.contains(id) {
                ready.append(account)
            } else {
                missing.append(account)
                log.record(.readClient, .clientMissing, subject: CredentialChainLog.subject(account: account))
            }
        }
        return .ready(accounts: ready, clientMissing: missing)
    }

    public func take(account email: String) async -> CredentialIntakeResult {
        let key = AccountCredentials.accountKey(email)
        let subject = CredentialChainLog.subject(account: key)
        func fail(_ step: CredentialStep, _ outcome: CredentialOutcome) -> CredentialIntakeResult {
            log.record(step, outcome, subject: subject)
            return .failed(outcome)
        }
        guard tokens.shared.canHoldSharedCopies else { return fail(.readSignIn, .noEntitlement) }
        let grant: SharedGrant
        do {
            switch try tokens.shared.read(account: key) {
            case .found(let found): grant = found
            case .missing: return fail(.readSignIn, .noItem)
            case .unavailable: return fail(.readSignIn, .noEntitlement)
            }
        } catch { return fail(.readSignIn, Self.outcome(error)) }
        do {
            guard try tokens.load(account: key)?.refreshToken == grant.refreshToken else {
                let choice = (try? tokens.device.load(account: key))?.choice
                return fail(.readSignIn, choice == nil ? .refusedHere : .keptLocal)
            }
        } catch { return fail(.readSignIn, Self.outcome(error)) }
        log.record(.readSignIn, .ok, subject: subject)
        guard let client = clients().first(where: { $0.clientID == grant.clientID }) else {
            return fail(.readClient, .clientMissing)
        }
        log.record(.readClient, .ok, subject: subject)
        let credentials = AccountCredentials(store: tokens, client: client, transport: transport, clock: clock,
                                             minimumValidity: .seconds(300), retryWaits: retryWaits, onEvent: nil,
                                             knownClients: nil, log: log)
        let manager = credentials.tokenManager(for: key)
        do {
            _ = try await manager.accessToken(forceRefresh: true)
        } catch OAuthError.reauthRequired {
            switch await manager.authState() {
            case .needsReauth(.broaderGrant): return .failed(.broaderGrant)
            case .needsReauth(.clientMismatch): return fail(.readClient, .clientMissing)
            case .needsReauth(.noToken): return fail(.readSignIn, .noItem)
            default:
                let code = await manager.lastRefusal() ?? "unknown"
                return .failed(.googleRefused(code: code))
            }
        } catch {
            let outcome = Self.outcome(error)
            if error is TokenStoreError { log.record(.refresh, outcome, subject: subject) }
            return .failed(outcome)
        }
        do { try tokens.setSource(.shared, account: key) } catch {
            Log(.keychain).error("shared sign-in: the device record could not note its source "
                                 + "(\(Self.outcome(error).summary))")
        }
        let scopes = (try? tokens.load(account: key))?.grantedScopes ?? grant.grantedScopes
        return .added(scopes: scopes)
    }

    private func unavailable(_ outcome: CredentialOutcome) -> CredentialIntakeState {
        log.record(.readSignIn, outcome)
        return .unavailable(outcome)
    }

    static func outcome(_ error: any Error) -> CredentialOutcome {
        if case TokenStoreError.keychain(let status) = error { return .keychain(status: status) }
        if case OAuthError.tokenEndpoint(let status, let code, _) = error {
            if status >= 500 { return .unreachable }
            if let code, status != 200 { return .googleRefused(code: CredentialChainLog.safeCode(code)) }
            return .unreadable
        }
        if error is TransportError || error is URLError { return .unreachable }
        return .unreadable
    }
}
