import Foundation
import MailModel
import OpenHumanCore

extension FakeMailStore {
    public func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        plainStream { s in s.oauthClient }
    }

    public func importOAuthClient(json: Data) async throws {
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        let installed = object?["installed"] as? [String: Any]
        guard let id = installed?["client_id"] as? String, !id.isEmpty,
              let secret = installed?["client_secret"] as? String, !secret.isEmpty else {
            throw AccountSetupError(.clientMissing, "That file isn't a Google Desktop client JSON.")
        }
        mutate { $0.oauthClient = .configured(source: .file) }
    }

    public func addAccount(loginHint: String?) async throws -> AccountID {
        try mutate { s in
            guard case .configured = s.oauthClient else {
                throw AccountSetupError(.clientMissing, "Set up the Google OAuth client first.")
            }
            guard !s.offline else { throw AccountSetupError(.failed, "Couldn't reach Google. Check the connection and try again.") }
            let outcome = s.signInOutcomes.isEmpty ? nil : s.signInOutcomes.removeFirst()
            let (email, name) = try Self.signIn(outcome, loginHint: loginHint, next: s.nextAccount)
            if let existing = s.accounts.values.first(where: { $0.account.email.lowercased() == email.lowercased() }) {
                return existing.account.id
            }
            let id = AccountID(s.nextAccount)
            s.nextAccount += 1
            let account = Account(id: id, email: email, displayName: name, alias: nil, health: .active,
                                  sendAs: [SenderIdentity(email: email, name: name, isDefault: true, isPrimary: true)])
            let important = FakeLabels.importantSplit(account: id, ids: &s.ids)
            let calendar = FakeLabels.calendarSplit(account: id, ids: &s.ids)
            s.accounts[id] = FakeAccountState(
                account: account, labels: FakeLabels.standard(account: id, ids: &s.ids), splits: [important, calendar],
                splitRules: [important.id: .term(key: "is", value: "important"),
                             calendar.id: .term(key: "is", value: "event")],
                connectivity: .online(syncing: true, lastSyncAt: nil))
            s.threadOrder[id] = []
            let hidden = AppSettings.hideSplitWhenEmpty(id)
            s.settings[SettingSlot(name: hidden.name, scope: hidden.scope)] = try? JSONEncoder().encode([calendar.id.rawValue])
            return id
        }
    }

    public func reauthorize(_ account: AccountID) async throws {
        let now = self.now
        let pending = try mutate { s -> [Int64] in
            guard let state = s.accounts[account] else { throw MailPortError.notFound("account") }
            guard !s.offline else { throw AccountSetupError(.failed, "Couldn't reach Google. Check the connection and try again.") }
            let outcome = s.signInOutcomes.isEmpty ? nil : s.signInOutcomes.removeFirst()
            let (email, _) = try Self.signIn(outcome, loginHint: state.account.email, next: account.rawValue)
            guard email.lowercased() == state.account.email.lowercased() else {
                throw AccountSetupError(.refused, "That's a different Google account. Sign in as \(state.account.email).")
            }
            s.accounts[account]?.account = Self.with(state.account, health: .active)
            s.accounts[account]?.connectivity = .online(syncing: false, lastSyncAt: now)
            s.invalidateAccount(account)
            let ids = s.operations.values.filter { $0.account == account && $0.status == .pending }.map(\.id)
            if options.remoteAck == .immediate { s.acknowledge(ids, now: now) }
            return ids
        }
        scheduleAcknowledgement(pending)
    }

    public func remove(_ account: AccountID) async throws {
        try mutate { s in
            guard s.accounts.removeValue(forKey: account) != nil else { throw MailPortError.notFound("account") }
            for key in s.threadOrder.removeValue(forKey: account) ?? [] {
                for message in s.threads.removeValue(forKey: key)?.messages ?? [] {
                    s.messageIndex.removeValue(forKey: message.summary.id)
                }
                s.reminders.removeValue(forKey: key)
                s.draftsByThread.removeValue(forKey: key)
                s.derived.removeValue(forKey: key)
            }
            for (id, draft) in s.drafts where draft.account == account { s.drafts.removeValue(forKey: id) }
            for (id, op) in s.operations where op.account == account && op.status == .pending {
                s.finish(id, as: .cancelled)
            }
            s.failures.removeAll { $0.account == account }
            s.snippets = s.snippets.filter { $0.value.account != account }
        }
    }

    public func setAlias(_ account: AccountID, _ alias: String?) async throws {
        try mutate { s in
            guard let state = s.accounts[account] else { throw MailPortError.notFound("account") }
            let trimmed = alias?.trimmingCharacters(in: .whitespaces)
            s.accounts[account]?.account = Account(
                id: state.account.id, email: state.account.email, displayName: state.account.displayName,
                alias: trimmed?.isEmpty == false ? trimmed : nil, health: state.account.health,
                sendAs: state.account.sendAs)
        }
    }

    static func signIn(_ outcome: FakeSignInOutcome?, loginHint: String?, next: Int64) throws -> (String, String?) {
        switch outcome {
        case .succeed(let email, let name): return (email, name)
        case .cancel: throw AccountSetupError(.cancelled, "Sign-in was cancelled.")
        case .refuse: throw AccountSetupError(.refused, "Google granted more than read-only access, so Mail refused the sign-in.")
        case .fail: throw AccountSetupError(.failed, "Sign-in failed. Try again.")
        case nil: return (loginHint ?? "new.account\(next)@example.org", nil)
        }
    }

    static func with(_ account: Account, health: AccountHealth) -> Account {
        Account(id: account.id, email: account.email, displayName: account.displayName, alias: account.alias,
                health: health, sendAs: account.sendAs)
    }

    public func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> {
        plainStream { s in s.setting(key) }
    }

    public func get<V>(_ key: AppSettingKey<V>) async throws -> V {
        state.withLock { $0.setting(key) }
    }

    public func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws {
        let data = try JSONEncoder().encode(value)
        mutate { s in s.settings[SettingSlot(name: key.name, scope: key.scope)] = data }
    }
}
