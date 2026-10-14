import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class AccountsSettingsModel {
    public struct Row: Identifiable, Hashable {
        public let id: AccountID
        public let email: String
        public let name: String
        public let alias: String
        public let status: String
        public let needsSignIn: Bool
        public let fromChoices: [String]
        public let defaultFrom: String?
        public let replyFrom: ReplyFromPolicy
        public let clientShortID: String?
        public let signInSyncNote: String?
        public let dontSyncSignIn: Bool
        public let canChangeSignInSync: Bool
    }

    public struct ClientRow: Identifiable, Hashable {
        public let id: OAuthClientSummary.ID
        public let title: String
        public let usedBy: String
        public let calendars: String?
        public let imported: String?
        public let isImported: Bool
        public let syncNote: String?
        public let dontSync: Bool
    }

    public struct ClientMove: Equatable {
        public let from: OAuthClientSummary.ID
        public let fromShortID: String
        public let to: OAuthClientSummary.ID
        public let toShortID: String
        public let accounts: [AccountID]
        public let calendars: [AccountID]
        let json: Data
    }

    public private(set) var rows: [Row] = []
    public private(set) var clients: [OAuthClientSummary] = []
    public private(set) var clientUsage: [OAuthClientUsage] = []
    public private(set) var pendingMove: ClientMove?
    public private(set) var clientNotice: String?
    public private(set) var isMoving = false
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var confirmingRemoval: AccountID?
    public private(set) var removalOffersSharedSignIn = false
    public private(set) var keychainNote = SignInModel.keychainLocalNote
    public let availability: SettingsAvailability

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let accounts: (any AccountManaging)?
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var latest: [Account] = []
    @ObservationIgnored private var from: [AccountID: String?] = [:]
    @ObservationIgnored private var policy: [AccountID: ReplyFromPolicy] = [:]
    @ObservationIgnored private var connectivity: [AccountID: ConnectivityState] = [:]
    @ObservationIgnored private var settingTasks: [AccountID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var clientShortIDs: [AccountID: String] = [:]
    @ObservationIgnored private var signInSyncs: [AccountID: SignInSync] = [:]
    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private var clientsResolved = false

    public init(data: any MailDataSource, accounts: (any AccountManaging)?, settings: (any SettingsPort)?,
                availability: SettingsAvailability) {
        self.data = data
        self.accounts = accounts
        self.settings = settings
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, accounts: environment.accounts, settings: environment.settings,
                  availability: SettingsAvailability(environment: environment))
    }

    isolated deinit {
        task?.cancel()
        clientTask?.cancel()
        for tasks in settingTasks.values { for task in tasks { task.cancel() } }
    }

    public func start() {
        guard task == nil else { return }
        let data = self.data
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    do {
                        for try await list in data.accounts() {
                            guard !Task.isCancelled else { return }
                            await self?.accountsChanged(list)
                        }
                    } catch {}
                }
                group.addTask { [weak self] in
                    for await states in data.connectivity() {
                        guard !Task.isCancelled else { return }
                        await self?.connectivityChanged(states)
                    }
                }
            }
        }
    }

    private func accountsChanged(_ list: [Account]) {
        latest = list
        observeSettings(for: list)
        rebuild()
        refreshClients()
    }

    private func refreshClients() {
        guard let accounts else { return }
        let ids = latest.map(\.id)
        clientTask?.cancel()
        clientTask = Task { [weak self] in
            let known = await accounts.oauthClients()
            var shortIDs: [AccountID: String] = [:]
            var syncs: [AccountID: SignInSync] = [:]
            for id in ids {
                if let short = await accounts.oauthClientShortID(for: id) { shortIDs[id] = short }
                if let sync = await accounts.signInSync(for: id) { syncs[id] = sync }
            }
            let usage = await accounts.oauthClientUsage()
            guard !Task.isCancelled else { return }
            self?.clientsLoaded(known, shortIDs, usage, syncs)
            await self?.loadKeychainNote()
        }
    }

    private func clientsLoaded(_ known: [OAuthClientSummary], _ shortIDs: [AccountID: String],
                               _ usage: [OAuthClientUsage], _ syncs: [AccountID: SignInSync]) {
        clients = known
        clientUsage = usage
        clientShortIDs = shortIDs
        signInSyncs = syncs
        clientsResolved = true
        rebuild()
    }

    private func connectivityChanged(_ states: [AccountID: ConnectivityState]) {
        connectivity = states
        rebuild()
    }

    private func observeSettings(for list: [Account]) {
        guard let settings else { return }
        let ids = Set(list.map(\.id))
        for id in settingTasks.keys where !ids.contains(id) {
            settingTasks[id]?.forEach { $0.cancel() }
            settingTasks[id] = nil
        }
        for id in ids where settingTasks[id] == nil {
            let fromTask = Task { [weak self] in
                for await value in settings.observe(ComposeSettings.defaultFrom(id)) {
                    guard !Task.isCancelled else { return }
                    self?.from[id] = .some(value)
                    self?.rebuild()
                }
            }
            let policyTask = Task { [weak self] in
                for await value in settings.observe(ComposeSettings.replyFrom(id)) {
                    guard !Task.isCancelled else { return }
                    self?.policy[id] = value
                    self?.rebuild()
                }
            }
            settingTasks[id] = [fromTask, policyTask]
        }
    }

    private func rebuild() {
        guard accounts == nil || clientsResolved else { return }
        rows = latest.map { account in
            let choices = FromResolver.identities(of: account).filter { !$0.needsVerification }.map(\.email)
            let stored = from[account.id] ?? nil
            let chosen = stored.flatMap { value in choices.first { $0.caseInsensitiveCompare(value) == .orderedSame } }
            return Row(id: account.id, email: account.email, name: account.displayName ?? account.email,
                       alias: account.alias ?? "", status: Self.status(account, connectivity[account.id]),
                       needsSignIn: account.health == .needsSignIn, fromChoices: choices, defaultFrom: chosen,
                       replyFrom: policy[account.id] ?? ComposeSettings.replyFrom(account.id).defaultValue,
                       clientShortID: clientShortIDs[account.id],
                       signInSyncNote: Self.signInSyncNote(signInSyncs[account.id]),
                       dontSyncSignIn: signInSyncs[account.id].map(Self.dontSync) ?? false,
                       canChangeSignInSync: signInSyncs[account.id].map { $0 != .needsSignInHere } ?? false)
        }
    }

    static func status(_ account: Account, _ state: ConnectivityState?) -> String {
        switch account.health {
        case .needsSignIn: return "Needs sign-in"
        case .disabled: return "Paused"
        case .removing: return "Signing out"
        case .active: break
        }
        switch state {
        case .needsReauth: return "Needs sign-in"
        case .offline: return "Offline"
        case .rateLimited: return "Gmail asked Mail to slow down"
        case .syncFailing: return "Sync is failing; trying again"
        case .online(let syncing, let last):
            if syncing { return "Syncing" }
            guard let last else { return "Waiting for the first sync" }
            return "Synced " + last.formatted(.relative(presentation: .named))
        case nil: return "Signed in"
        }
    }

    public func setAlias(_ alias: String, for account: AccountID) async {
        guard let accounts else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        await attempt { try await accounts.setAlias(account, trimmed.isEmpty ? nil : trimmed) }
    }

    public func setDefaultFrom(_ email: String?, for account: AccountID) async {
        guard let settings else { return }
        let value = email?.lowercased()
        await attempt { try await settings.set(ComposeSettings.defaultFrom(account), value) }
    }

    public func setReplyFrom(_ policy: ReplyFromPolicy, for account: AccountID) async {
        guard let settings else { return }
        await attempt { try await settings.set(ComposeSettings.replyFrom(account), policy) }
    }

    public var canAddAccount: Bool { accounts != nil && !isAdding }

    public var selectedClient: OAuthClientSummary? {
        clients.first(where: \.isSelected) ?? clients.first(where: \.isDefault)
    }

    public var showsClientPicker: Bool { clients.count > 1 }

    public func selectClient(_ id: OAuthClientSummary.ID) async {
        guard let accounts, !isAdding else { return }
        await attempt { try await accounts.selectOAuthClient(id) }
        refreshClients()
    }

    public func importClient(json: Data) async {
        guard let accounts, !isAdding else { return }
        await attempt { try await accounts.importOAuthClient(json: json) }
        refreshClients()
    }

    public func importFailed() {
        errorMessage = "That file couldn't be read."
    }

    public func addAccount() async {
        guard let accounts, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        await attempt { _ = try await accounts.addAccount(loginHint: nil) }
    }

    @discardableResult
    public func addAccountIfRequested(by navigator: SettingsNavigator) -> Task<Void, Never>? {
        guard navigator.takeAddAccountRequest() else { return nil }
        return Task { await addAccount() }
    }

    public func reauthorize(_ account: AccountID) async {
        guard let accounts else { return }
        await attempt { try await accounts.reauthorize(account) }
    }

    public static let removalConfirmationTitle = "Sign out of this account?"
    public static let removalConfirmationMessage = "Mail removes this account from this Mac only: its downloaded mail, "
        + "attachments, local drafts, AI results, Spotlight entries, notifications and the sign-in kept in this Mac's "
        + "Keychain. Nothing changes in Gmail; no message is deleted there. This can't be undone with ⌘Z. To get the "
        + "mail back, sign in again and Mail downloads it again."
    public static let removalConfirmationButton = "Sign out of this Mac"
    public static let removalSharedSignInButton = "Sign out and remove from iCloud Keychain"
    public static let removalSharedSignInNote = "iCloud Keychain also syncs this sign-in to your other devices, and they "
        + "keep it. “\(removalSharedSignInButton)” deletes it there too, so devices that rely on it will need to sign "
        + "in again."

    public var removalMessage: String {
        removalOffersSharedSignIn ? Self.removalConfirmationMessage + " " + Self.removalSharedSignInNote
            : Self.removalConfirmationMessage
    }

    public func loadKeychainNote() async {
        keychainNote = SignInModel.keychainNote(syncs: await accounts?.signInsSyncThroughICloudKeychain() ?? false)
    }

    public func askToRemove(_ account: AccountID) async {
        let sync = await accounts?.signInSync(for: account)
        removalOffersSharedSignIn = sync == .syncing
        confirmingRemoval = account
    }

    public func cancelRemoval() {
        confirmingRemoval = nil
        removalOffersSharedSignIn = false
    }

    @discardableResult
    public func confirmRemoval(includingSharedSignIn: Bool = false) -> Task<Void, Never>? {
        guard let id = confirmingRemoval, let accounts, !includingSharedSignIn || removalOffersSharedSignIn else {
            return nil
        }
        cancelRemoval()
        return Task {
            await attempt {
                if includingSharedSignIn {
                    try await accounts.removeIncludingSharedSignIn(id)
                } else {
                    try await accounts.remove(id)
                }
            }
        }
    }

    private var emailsByID: [AccountID: String] {
        Dictionary(latest.map { ($0.id, $0.email) }, uniquingKeysWith: { first, _ in first })
    }

    private func names(_ ids: [AccountID]) -> String {
        let emails = emailsByID
        let names = ids.map { emails[$0] ?? "an account" }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    public var clientRows: [ClientRow] {
        clientUsage.map { usage in
            ClientRow(id: usage.id, title: "Client " + usage.client.title,
                      usedBy: usage.accounts.isEmpty ? "No account signs in with it" : "Used by " + names(usage.accounts),
                      calendars: usage.calendars.isEmpty ? nil : "Calendar of " + names(usage.calendars),
                      imported: usage.importedAt.map { "Imported " + $0.formatted(date: .abbreviated, time: .omitted) },
                      isImported: usage.hasImportedFile, syncNote: Self.syncNote(usage.sync),
                      dontSync: usage.sync == .notSyncing)
        }
    }

    public static func syncNote(_ sync: OAuthClientSync?) -> String? {
        switch sync {
        case nil: return nil
        case .syncing?: return "Syncs through iCloud Keychain to your other devices."
        case .notSyncing?: return "Stays on this Mac. It does not sync."
        case .unavailable?: return "Couldn't sync: this copy of Mail can't use iCloud Keychain, so it stays on this Mac."
        }
    }

    public func setDontSync(_ id: OAuthClientSummary.ID, _ dontSync: Bool) async {
        guard let accounts, canChangeClients else { return }
        clientNotice = nil
        await attempt { try await accounts.setOAuthClientSync(id, enabled: !dontSync) }
        refreshClients()
    }

    public var canChangeClients: Bool { accounts != nil && !isAdding && !isMoving }

    public static func signInSyncNote(_ sync: SignInSync?) -> String? {
        switch sync {
        case nil: return nil
        case .syncing?: return "Shared with your other devices through iCloud Keychain, so they can use this account "
            + "without signing in."
        case .pending?: return "Shares with your other devices through iCloud Keychain the next time Mail opens."
        case .notSyncing?: return "Stays on this Mac. Your other devices sign in on their own."
        case .unavailable?: return "Couldn't share: this copy of Mail can't use iCloud Keychain, so the sign-in stays "
            + "on this Mac."
        case .ownSignInHere?: return "The sign-in from your other device didn't work here, so this Mac uses its own."
        case .needsSignInHere?: return "The sign-in from your other device didn't work on this Mac. Sign in again here."
        }
    }

    static func dontSync(_ sync: SignInSync) -> Bool { sync == .notSyncing || sync == .ownSignInHere }

    public func setDontSyncSignIn(_ account: AccountID, _ dontSync: Bool) async {
        guard let accounts, canChangeClients else { return }
        await attempt { try await accounts.setSignInSync(account, enabled: !dontSync) }
        refreshClients()
    }

    private func shortID(_ id: OAuthClientSummary.ID) -> String {
        clientUsage.first { $0.id == id }?.client.shortID ?? clients.first { $0.id == id }?.shortID ?? ""
    }

    public func removeClient(_ id: OAuthClientSummary.ID) async {
        guard let accounts, canChangeClients else { return }
        clientNotice = nil
        if let usage = clientUsage.first(where: { $0.id == id }), let reason = usage.removalRefusal(emails: emailsByID) {
            errorMessage = reason
            return
        }
        let short = shortID(id)
        var removed = false
        await attempt {
            try await accounts.removeOAuthClient(id)
            removed = true
        }
        if removed {
            clientNotice = "Removed client …\(short) from this Mac's Keychain (and from iCloud Keychain, if it synced). "
                + "Nothing changed at Google."
        }
        refreshClients()
    }

    public func replaceClient(_ id: OAuthClientSummary.ID, json: Data) async {
        guard let accounts, canChangeClients else { return }
        clientNotice = nil
        errorMessage = nil
        let short = shortID(id)
        let kind: OAuthClientReplacement
        do {
            kind = try await accounts.inspectOAuthClientFile(json, replacing: id)
        } catch {
            show(error)
            return
        }
        switch kind {
        case .sameClient:
            var replaced = false
            await attempt {
                try await accounts.replaceOAuthClient(id, json: json)
                replaced = true
            }
            if replaced {
                clientNotice = "Updated client …\(short) from the new file. Accounts already open use it after Mail restarts."
            }
            refreshClients()
        case .differentClient(let newID, let newShort):
            let usage = clientUsage.first { $0.id == id }
            pendingMove = ClientMove(from: id, fromShortID: short, to: newID, toShortID: newShort,
                                     accounts: usage?.accounts ?? [], calendars: usage?.calendars ?? [], json: json)
        }
    }

    public func moveTitle(_ move: ClientMove) -> String {
        move.accounts.isEmpty ? "Add client …\(move.toShortID)?"
            : "Sign in again with client …\(move.toShortID)?"
    }

    public func moveMessage(_ move: ClientMove) -> String {
        let old = "…\(move.fromShortID)", new = "…\(move.toShortID)"
        var text: String
        if move.accounts.isEmpty {
            text = "That file is another client. No account signs in with \(old), so Mail adds \(new) as another client."
        } else {
            let they = move.accounts.count == 1 ? "it" : "they"
            text = "That file is another client. \(names(move.accounts)) signed in with \(old); to use \(new) \(they) "
                + "must sign in again. Mail opens Google's sign-in for each, one at a time. Until a sign-in finishes, "
                + "that account keeps \(old)."
        }
        if !move.calendars.isEmpty {
            text += " The calendar of \(names(move.calendars)) stays connected with \(old) until you connect it again in "
                + "Settings › Calendar."
        }
        return text + " \(old) stays on this Mac until you remove it."
    }

    public func moveButton(_ move: ClientMove) -> String {
        move.accounts.isEmpty ? "Add Client" : "Sign In Again"
    }

    public func cancelMove() { pendingMove = nil }

    public func confirmMove() async {
        guard let move = pendingMove, let accounts else { return }
        pendingMove = nil
        isMoving = true
        defer { isMoving = false }
        errorMessage = nil
        clientNotice = nil
        do {
            try await accounts.importOAuthClient(json: move.json)
        } catch {
            show(error)
            refreshClients()
            return
        }
        var moved: [AccountID] = []
        for account in move.accounts {
            do {
                try await accounts.moveAccount(account, toOAuthClient: move.to)
                moved.append(account)
            } catch {
                show(error)
                let reason = errorMessage ?? "Sign-in was cancelled."
                errorMessage = "\(names([account])) still signs in with …\(move.fromShortID). \(reason)"
                break
            }
        }
        if move.accounts.isEmpty {
            clientNotice = "Added client …\(move.toShortID)."
        } else if !moved.isEmpty {
            clientNotice = "\(names(moved)) signed in again with …\(move.toShortID)."
        }
        refreshClients()
    }

    private func attempt(_ work: () async throws -> Void) async {
        errorMessage = nil
        do { try await work() } catch { show(error) }
    }

    private func show(_ error: Error) {
        if let setup = error as? AccountSetupError, setup.kind == .cancelled { return }
        errorMessage = (error as? AccountSetupError)?.message ?? (error as? MailPortError)?.description
            ?? "That didn't work. Try again."
    }
}
