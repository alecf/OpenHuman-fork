import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension MailEngine {
    static let signInTimeout: Duration = .seconds(300)

    public func setOAuthClient(_ config: OAuthClientConfig) async {
        oauthClient = config
    }

    public func addAccount(using flow: OAuthFlow, loginHint: String?) async throws -> AccountItem {
        let (key, result) = try await authorize(flow, loginHint: loginHint, expected: nil)
        let id = try store.addAccount(email: key, displayName: nil, scopes: result.token.grantedScopes)
        log.notice("account \(id.rawValue): added (scopes \(OAuthScopes.carriesMailWrite(result.token.grantedScopes) ? "write" : "read-only"))")
        guard let item = try store.accounts().first(where: { $0.id == id }) else {
            throw StoreError.notFound("account \(id.rawValue)")
        }
        if started { await startAccount(item) }
        return item
    }

    public func reauthorize(_ account: AccountID, using flow: OAuthFlow) async throws {
        guard let item = try store.accounts().first(where: { $0.id == account }) else {
            throw StoreError.notFound("account \(account.rawValue)")
        }
        let (key, result) = try await authorize(flow, loginHint: item.email, expected: item.email)
        _ = try store.addAccount(email: key, displayName: nil, scopes: result.token.grantedScopes)
        connectivity.set(account, nil)
        if let runtime = runtimes.removeValue(forKey: account) { await runtime.stop() }
        if started, let fresh = try store.accounts().first(where: { $0.id == account }) {
            if await ownership?.isOwner(account) == true { await launchRuntimeAfterReauth(fresh) } else { await startAccount(fresh) }
        }
    }

    public func removeAccount(_ account: AccountID) async throws {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "removeAccount")
        guard let item = try store.accounts().first(where: { $0.id == account }) else {
            throw StoreError.notFound("account \(account.rawValue)")
        }
        if let runtime = runtimes.removeValue(forKey: account) { await runtime.stop() }
        await ownership?.release(account)
        connectivity.set(account, nil)
        try tokenStore?.delete(account: AccountCredentials.accountKey(item.email))
        (gmailFactory as? DefaultGmailClientFactory)?.invalidate(accountEmail: item.email)
        try store.setAccountStatus(account, .removing)
        try store.removeAccountData(account) { _ in }
        log.notice("account \(account.rawValue): removed locally")
    }

    public func handle(_ event: TokenEvent) async {
        guard let accounts = try? store.accounts() else { return }
        switch event {
        case let .needsReauth(email, reason):
            guard let item = accounts.first(where: { AccountCredentials.accountKey($0.email) == email }) else { return }
            log.notice("account \(item.id.rawValue): needs reauth (\(reason.rawValue))")
            try? store.setAccountStatus(item.id, .needsReauth)
            connectivity.set(item.id, .needsReauth)
            eventSink.yield(.accountNeedsReauth(item.id))
        case let .scopesChanged(email, scopes):
            guard let item = accounts.first(where: { AccountCredentials.accountKey($0.email) == email }) else { return }
            let couldWrite = EnginePolicy.grantAllowsWrites(item)
            _ = try? store.addAccount(email: item.email, displayName: nil, scopes: scopes)
            guard couldWrite != scopes.contains(GmailScope.modify), started,
                  let fresh = try? store.accounts().first(where: { $0.id == item.id }) else { return }
            if let runtime = runtimes.removeValue(forKey: item.id) { await runtime.stop() }
            await launchRuntimeAfterReauth(fresh)
        case .authorized, .signedOut:
            break
        }
    }

    private func authorize(_ flow: OAuthFlow, loginHint: String?,
                           expected: String?) async throws -> (String, OAuthResult) {
        try EnginePolicy.checkNetwork(role: configuration.role, what: "sign-in")
        guard let tokenStore else { throw EngineError.requiresApp("sign-in needs the app's token store") }
        guard oauthClient != nil || !flow.client.clientID.isEmpty else { throw EngineError.oauthClientMissing }
        let mode = configuration.safeMode
        guard Set(flow.scopes) == Set(mode.oauthScopes) else {
            throw EngineError.blockedBySafeMode("sign-in must request exactly the \(mode.rawValue) scope")
        }
        let result = try await flow.authorize(loginHint: loginHint, timeout: Self.signInTimeout)
        let granted = result.token.grantedScopes
        let missing = OAuthScopes.missing(mode.oauthScopes, in: granted)
        if !missing.isEmpty { throw OAuthError.insufficientScopes(missing: missing) }
        if mode == .readOnly, OAuthScopes.carriesMailWrite(granted) {
            throw EngineError.blockedBySafeMode("the token carries a write scope; read-only mode refuses it")
        }
        let key = AccountCredentials.accountKey(result.email)
        guard !key.isEmpty else { throw OAuthError.denied("invalid_account") }
        if let expected, AccountCredentials.accountKey(expected) != key {
            log.error("reauthorization returned a different Google account; nothing was stored")
            throw OAuthError.denied("account_mismatch")
        }
        try tokenStore.save(result.token, account: key)
        (gmailFactory as? DefaultGmailClientFactory)?.invalidate(accountEmail: key)
        return (key, result)
    }

    private func launchRuntimeAfterReauth(_ account: AccountItem) async {
        guard runtimes[account.id] == nil, await ownership?.isOwner(account.id) == true else { return }
        await launchRuntime(account)
    }
}
