import CryptoKit
import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailApple
import Synchronization

struct SignInBrowserPlatform: Sendable {
    var openDefault: @Sendable (URL) async throws -> Void
    var openWith: @Sendable (URL, InstalledBrowser) async throws -> Void
    var browsers: @Sendable () async -> [InstalledBrowser]

    init(openDefault: @escaping @Sendable (URL) async throws -> Void,
         openWith: @escaping @Sendable (URL, InstalledBrowser) async throws -> Void,
         browsers: @escaping @Sendable () async -> [InstalledBrowser]) {
        self.openDefault = openDefault
        self.openWith = openWith
        self.browsers = browsers
    }
}

protocol SignInBrowserMemory: Sendable {
    func browser(for account: String?) -> String?
    func remember(_ browser: String?, for account: String?)
}

struct UserDefaultsSignInBrowserMemory: SignInBrowserMemory, @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    static func key(_ account: String?) -> String {
        guard let account = account?.lowercased(), !account.isEmpty else { return "signin.browser.any" }
        let digest = SHA256.hash(data: Data(account.utf8))
        return "signin.browser." + digest.map { String(format: "%02x", $0) }.joined()
    }

    func browser(for account: String?) -> String? { defaults.string(forKey: Self.key(account)) }

    func remember(_ browser: String?, for account: String?) {
        if let browser { defaults.set(browser, forKey: Self.key(account)) } else { defaults.removeObject(forKey: Self.key(account)) }
    }
}

final class SignInBroker: ExternalBrowser, SignInBrowsing, Sendable {
    private struct Waiting {
        let pending: PendingSignIn
        let receiver: BrokeredReceiver
    }

    private struct State {
        var receivers: [String: BrokeredReceiver] = [:]
        var waiting: [Waiting] = []
        var watchers: [UUID: AsyncStream<PendingSignIn?>.Continuation] = [:]
    }

    private let platform: SignInBrowserPlatform
    private let memory: any SignInBrowserMemory
    private let state = Mutex(State())

    init(platform: SignInBrowserPlatform, memory: any SignInBrowserMemory) {
        self.platform = platform
        self.memory = memory
    }

    func wrap(_ receiver: any LoopbackRedirectReceiver) -> any LoopbackRedirectReceiver {
        BrokeredReceiver(inner: receiver, broker: self)
    }

    func open(_ url: URL) async throws {
        guard GoogleConsentLink.isValid(url) else {
            Log(.oauth).error("sign-in page refused: not Google's consent page")
            throw SystemBrowserError.unsupportedURL
        }
        let account = GoogleConsentLink.loginHint(url)?.lowercased()
        let purpose: PendingSignIn.Purpose = GoogleConsentLink.isCalendarConsent(url) ? .calendar : .email
        var openedIn: String?
        var failed = false
        let remembered = memory.browser(for: account)
        if let remembered, let browser = await platform.browsers().first(where: { $0.id == remembered }) {
            do {
                try await platform.openWith(url, browser)
                openedIn = browser.name
            } catch {
                failed = true
            }
        } else {
            do { try await platform.openDefault(url) } catch { failed = true }
        }
        if failed { Log(.oauth).notice("the sign-in page did not open in a browser; the waiting panel offers others") }
        let pending = PendingSignIn(url: url, account: account, purpose: purpose, openedIn: openedIn, openFailed: failed)
        let redirect = GoogleConsentLink.redirectURI(url)?.absoluteString ?? ""
        let published = state.withLock { s -> Bool in
            guard let receiver = s.receivers[redirect] else { return false }
            s.waiting.append(Waiting(pending: pending, receiver: receiver))
            return true
        }
        guard published else {
            if failed { throw SystemBrowserError.couldNotOpen }
            return
        }
        publish()
    }

    func pendingSignIns() -> AsyncStream<PendingSignIn?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PendingSignIn?>.makeStream()
        let current = state.withLock { s -> PendingSignIn? in
            s.watchers[id] = continuation
            return s.waiting.last?.pending
        }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        continuation.yield(current)
        return stream
    }

    func installedBrowsers() async -> [InstalledBrowser] { await platform.browsers() }

    func open(_ id: PendingSignIn.ID, in browser: InstalledBrowser.ID?) async throws {
        guard let pending = state.withLock({ s in s.waiting.first { $0.pending.id == id }?.pending }) else {
            throw SignInBrowserError("That sign-in has ended. Start it again.")
        }
        guard GoogleConsentLink.isValid(pending.url) else { throw SignInBrowserError("That isn't Google's sign-in page.") }
        if let browser {
            guard let app = await platform.browsers().first(where: { $0.id == browser }) else {
                throw SignInBrowserError("That browser isn't on this Mac any more. Pick another one.")
            }
            do { try await platform.openWith(pending.url, app) } catch {
                throw SignInBrowserError("\(app.name) didn't open. Pick another browser, or copy the link.")
            }
        } else {
            do { try await platform.openDefault(pending.url) } catch {
                throw SignInBrowserError("Your default browser didn't open. Pick another one, or copy the link.")
            }
        }
        memory.remember(browser, for: pending.account)
    }

    func rememberedBrowser(for account: String?) async -> InstalledBrowser.ID? {
        memory.browser(for: account?.lowercased())
    }

    func cancel(_ id: PendingSignIn.ID) async {
        let receiver = state.withLock { s in s.waiting.first { $0.pending.id == id }?.receiver }
        receiver?.cancelWait()
    }

    fileprivate func started(_ receiver: BrokeredReceiver, redirect: URL) {
        state.withLock { $0.receivers[redirect.absoluteString] = receiver }
    }

    fileprivate func stopped(_ receiver: BrokeredReceiver) {
        let changed = state.withLock { s -> Bool in
            s.receivers = s.receivers.filter { $0.value !== receiver }
            let before = s.waiting.count
            s.waiting.removeAll { $0.receiver === receiver }
            return s.waiting.count != before
        }
        if changed { publish() }
    }

    private func publish() {
        let (current, watchers) = state.withLock { s in (s.waiting.last?.pending, Array(s.watchers.values)) }
        for watcher in watchers { watcher.yield(current) }
    }

    var waitingCount: Int { state.withLock { $0.waiting.count } }
}

final class BrokeredReceiver: LoopbackRedirectReceiver, Sendable {
    private let inner: any LoopbackRedirectReceiver
    private let broker: SignInBroker
    private let cancelled: AsyncStream<Void>
    private let cancelSignal: AsyncStream<Void>.Continuation

    init(inner: any LoopbackRedirectReceiver, broker: SignInBroker) {
        self.inner = inner
        self.broker = broker
        (cancelled, cancelSignal) = AsyncStream<Void>.makeStream()
    }

    func start() async throws -> URL {
        let redirect = try await inner.start()
        broker.started(self, redirect: redirect)
        return redirect
    }

    func expectState(_ state: String) async { await inner.expectState(state) }

    func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        let inner = self.inner, cancelled = self.cancelled
        return try await withThrowingTaskGroup(of: URLComponents.self) { group in
            group.addTask { try await inner.waitForCallback(timeout: timeout, successHTML: successHTML) }
            group.addTask {
                for await _ in cancelled { throw OAuthError.cancelled }
                try Task.checkCancellation()
                throw OAuthError.cancelled
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthError.cancelled }
            return first
        }
    }

    func stop() async {
        await inner.stop()
        cancelSignal.finish()
        broker.stopped(self)
    }

    func cancelWait() {
        cancelSignal.yield(())
    }
}
