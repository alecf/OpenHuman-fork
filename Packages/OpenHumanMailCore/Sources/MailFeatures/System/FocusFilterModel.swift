import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class FocusFilterModel {
    public static let currentKey = "focus.filter.current"
    public static let heldKey = "focus.filter.held"
    public static let ignoredKey = "focus.filter.ignored"
    public static let maxHeld = 500

    public private(set) var active: FocusFilterState?

    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var readyTimeout: Duration = .seconds(10)
    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private let platform: SystemPlatform
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var launchTask: Task<Void, Never>?

    init(environment: AppEnvironment, platform: SystemPlatform, defaults: UserDefaults) {
        self.environment = environment
        self.platform = platform
        self.defaults = defaults
    }

    isolated deinit {
        launchTask?.cancel()
    }

    public func start() {
        guard launchTask == nil else { return }
        if let stored = storedState, stored.identity != ignoredIdentity { active = stored }
        onChange?()
        launchTask = Task { [weak self] in
            guard let platform = self?.platform else { return }
            let current = await platform.currentFocusFilter()
            guard !Task.isCancelled else { return }
            await self?.apply(current)
        }
    }

    func waitForLaunch() async { await launchTask?.value }

    public func stop() async {
        launchTask?.cancel()
        launchTask = nil
        active = nil
        defaults.removeObject(forKey: Self.currentKey)
        defaults.removeObject(forKey: Self.ignoredKey)
        onChange?()
        await releaseHeld()
    }

    public func apply(_ incoming: FocusFilterState?) async {
        let signedIn = await signedInAccounts()
        let state = incoming?.keeping(signedIn)
        let previous = storedState?.identity
        let identity = state?.identity
        if let state, let data = state.encoded() {
            defaults.set(data, forKey: Self.currentKey)
        } else {
            defaults.removeObject(forKey: Self.currentKey)
        }
        if identity != previous { defaults.removeObject(forKey: Self.ignoredKey) }
        let ignored = identity != nil && identity == ignoredIdentity
        active = ignored ? nil : state
        onChange?()
        await releaseHeld()
        guard let state, !ignored, identity != previous else { return }
        await bringForward(state)
    }

    public func ignoreUntilChanged() async {
        guard let identity = active?.identity else { return }
        defaults.set(identity, forKey: Self.ignoredKey)
        active = nil
        onChange?()
        await releaseHeld()
    }

    private func bringForward(_ state: FocusFilterState) async {
        let router = environment.router
        guard await windowReady(router), let first = state.accounts.first,
              let index = router.accounts.firstIndex(where: { $0.id == first }) else { return }
        if router.composerContext?() != nil || platform.isAuthorTyping() {
            let name = Self.displayName(router.accounts[index].account, position: index + 1)
            environment.notices.post("A Focus put \(name) first. ⌃\(index + 1) shows \(name).", style: .info,
                                     duration: NoticeCenter.infoDuration)
            return
        }
        router.switchAccount(to: first)
        switch state.openOn {
        case .important: router.goToImportant()
        case .inbox: router.goToInbox()
        case .stay: break
        }
    }

    public func holdsNewMail(for account: AccountID) -> Bool {
        guard let active, active.holdOtherNotifications else { return false }
        return !active.accounts.contains(account)
    }

    public func hold(_ threads: [ThreadKey]) {
        var list = held
        for key in threads where !list.contains(key) { list.append(key) }
        if list.count > Self.maxHeld { list.removeFirst(list.count - Self.maxHeld) }
        held = list
    }

    public internal(set) var held: [ThreadKey] {
        get {
            guard let data = defaults.data(forKey: Self.heldKey) else { return [] }
            return (try? JSONDecoder().decode([ThreadKey].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.heldKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.heldKey)
            }
        }
    }

    private func releaseHeld() async {
        let list = held
        let releasing = list.filter { !holdsNewMail(for: $0.account) }
        guard !releasing.isEmpty else { return }
        held = list.filter { holdsNewMail(for: $0.account) }
        let byAccount = Dictionary(grouping: releasing, by: \.account)
        for account in byAccount.keys.sorted() {
            let keys = Set(byAccount[account] ?? [])
            let window = await Self.firstValue(environment.data.threadWindow(.system(.inbox), account: account, limit: 2_000))
            let count = (window?.rows ?? []).filter { keys.contains($0.id) && $0.isUnread }.count
            guard count > 0 else { continue }
            await environment.system.notifications?.postFocusSummary(account: account, name: name(of: account),
                                                                     count: count)
        }
    }

    public var badgeAccounts: Set<AccountID>? {
        guard let active, active.badgeOnlyTheseAccounts else { return nil }
        return Set(active.accounts)
    }

    public var statusLine: String? {
        guard let active, let first = active.accounts.first else { return nil }
        var line = "Focus: \(name(of: first)) first"
        if let held = heldNames(active) { line += " · \(held) notifications held" }
        return line
    }

    public var settingsStatus: String {
        guard let active, let first = active.accounts.first else { return "No Focus filter is active." }
        var text = "A Focus filter is on: \(name(of: first)) first, " + Self.openOnText(active.openOn) + "."
        if let held = heldNames(active) { text += " \(held) notifications held." }
        if active.badgeOnlyTheseAccounts {
            text += " The badge counts \(active.accounts.map { name(of: $0) }.joined(separator: ", ")) only."
        }
        return text
    }

    static func openOnText(_ openOn: FocusFilterState.OpenOn) -> String {
        switch openOn {
        case .important: "opens on Important"
        case .inbox: "opens on Inbox"
        case .stay: "stays where you left it"
        }
    }

    private func heldNames(_ state: FocusFilterState) -> String? {
        guard state.holdOtherNotifications else { return nil }
        let others = environment.router.accounts.filter { !state.accounts.contains($0.id) }.map { name(of: $0.id) }
        return others.isEmpty ? nil : others.joined(separator: ", ")
    }

    func name(of account: AccountID) -> String {
        let states = environment.router.accounts
        guard let index = states.firstIndex(where: { $0.id == account }) else { return "another account" }
        return Self.displayName(states[index].account, position: index + 1)
    }

    static func displayName(_ account: Account, position: Int) -> String {
        if let alias = account.alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty { return alias }
        return "Account \(position)"
    }

    private var storedState: FocusFilterState? { FocusFilterState.decoded(defaults.data(forKey: Self.currentKey)) }
    private var ignoredIdentity: String? { defaults.string(forKey: Self.ignoredKey) }

    private func signedInAccounts() async -> [AccountID] {
        (await Self.firstValue(environment.data.accounts()) ?? []).map(\.id)
    }

    private func windowReady(_ router: AppRouter) async -> Bool {
        let poll: Duration = .milliseconds(100)
        var waited: Duration = .zero
        while !router.accountsLoaded {
            guard waited < readyTimeout else { return false }
            try? await sleep(poll)
            waited += poll
        }
        return true
    }

    private static func firstValue<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async -> T? {
        do {
            for try await value in stream { return value }
        } catch {}
        return nil
    }
}
