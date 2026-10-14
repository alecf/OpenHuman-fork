import Foundation
import MailModel
import Synchronization

public final class FakeSignInBrowsing: SignInBrowsing, Sendable {
    private struct State {
        var pending: PendingSignIn?
        var watchers: [UUID: AsyncStream<PendingSignIn?>.Continuation] = [:]
        var opened: [(PendingSignIn.ID, InstalledBrowser.ID?)] = []
        var cancelled: [PendingSignIn.ID] = []
        var remembered: [String: InstalledBrowser.ID] = [:]
        var openFailure: String?
    }
    private let state: Mutex<State>
    private let browsers: [InstalledBrowser]

    public init(pending: PendingSignIn? = nil, browsers: [InstalledBrowser] = FakeSignInBrowsing.sampleBrowsers) {
        state = Mutex(State(pending: pending))
        self.browsers = browsers
    }

    public static let sampleBrowsers = [
        InstalledBrowser(id: "com.example.browser.alpha", name: "Alpha Browser", appPath: "/Applications/Alpha Browser.app"),
        InstalledBrowser(id: "com.example.browser.beta", name: "Beta Browser", appPath: "/Applications/Beta Browser.app"),
        InstalledBrowser(id: "com.example.browser.gamma", name: "Gamma Browser", appPath: "/Applications/Gamma Browser.app"),
    ]

    public static func sampleSignIn(account: String? = "robin@example.com", purpose: PendingSignIn.Purpose = .email,
                                    openedIn: String? = nil, openFailed: Bool = false) -> PendingSignIn {
        let url = URL(string: "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=sample-client.apps"
            + ".googleusercontent.com&redirect_uri=http://127.0.0.1:53682/oauth2callback&scope=sample&code_challenge="
            + "sample-challenge&code_challenge_method=S256&state=sample-state&access_type=offline&prompt=consent")!
        return PendingSignIn(url: url, account: account, purpose: purpose, openedIn: openedIn, openFailed: openFailed)
    }

    public func pendingSignIns() -> AsyncStream<PendingSignIn?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PendingSignIn?>.makeStream()
        let current = state.withLock { s -> PendingSignIn? in
            s.watchers[id] = continuation
            return s.pending
        }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        continuation.yield(current)
        return stream
    }

    public func installedBrowsers() async -> [InstalledBrowser] { browsers }

    public func open(_ id: PendingSignIn.ID, in browser: InstalledBrowser.ID?) async throws {
        let failure = state.withLock { s -> String? in
            s.opened.append((id, browser))
            if s.openFailure == nil, let account = s.pending?.account?.lowercased() { s.remembered[account] = browser }
            return s.openFailure
        }
        if let failure { throw SignInBrowserError(failure) }
    }

    public func rememberedBrowser(for account: String?) async -> InstalledBrowser.ID? {
        state.withLock { s in account.flatMap { s.remembered[$0.lowercased()] } }
    }

    public func cancel(_ id: PendingSignIn.ID) async {
        state.withLock { $0.cancelled.append(id) }
        set(nil)
    }

    public func set(_ pending: PendingSignIn?) {
        let watchers = state.withLock { s -> [AsyncStream<PendingSignIn?>.Continuation] in
            s.pending = pending
            return Array(s.watchers.values)
        }
        for watcher in watchers { watcher.yield(pending) }
    }

    public func remember(_ browser: InstalledBrowser.ID, for account: String) {
        state.withLock { $0.remembered[account.lowercased()] = browser }
    }

    public func failOpening(_ message: String?) { state.withLock { $0.openFailure = message } }

    public var openedBrowsers: [InstalledBrowser.ID?] { state.withLock { $0.opened.map(\.1) } }
    public var cancelled: [PendingSignIn.ID] { state.withLock { $0.cancelled } }
}

@MainActor
public final class FakeSignInClipboard: SignInClipboard {
    public private(set) var text: String?
    public private(set) var changeCount = 0
    public private(set) var clears = 0

    public init() {}

    public func copy(_ text: String) -> Int {
        self.text = text
        changeCount += 1
        return changeCount
    }

    @discardableResult
    public func clear(ifUnchangedSince mark: Int) -> Bool {
        guard changeCount == mark else { return false }
        text = nil
        changeCount += 1
        clears += 1
        return true
    }

    public func somethingElseCopied(_ other: String) {
        text = other
        changeCount += 1
    }
}
