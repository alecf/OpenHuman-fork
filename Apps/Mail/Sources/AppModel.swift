import AppKit
import Foundation
import MailFeatures
import MailModel
import MailUI
import Observation
import OpenHumanCore
import OpenHumanStore

@MainActor
@Observable
final class AppModel {
    enum Screen {
        case launching
        case mail(AppEnvironment)
        case signIn(SignInModel)
        case notice(StartupProblem)
    }

    private(set) var screen: Screen
    @ObservationIgnored private(set) var session: SyncSession?

    var router: AppRouter? {
        if case .mail(let environment) = screen { return environment.router }
        return nil
    }
    @ObservationIgnored private(set) lazy var deepLinks: DeepLinkRouter = {
        let links = DeepLinkRouter(router: { [weak self] in self?.router })
        links.didFollow = { _ in NSApp.activate() }
        return links
    }()
    @ObservationIgnored private(set) lazy var intents: IntentActions = IntentActions(router: { [weak self] in self?.router },
                                                                                  links: deepLinks)
    @ObservationIgnored private let live: LiveBackend?
    var liveAccounts: LiveAccountManager? { live?.accounts }
    @ObservationIgnored var platform: (@MainActor () -> SystemPlatform)?

    init(screen: Screen, session: SyncSession? = nil, platform: (@MainActor () -> SystemPlatform)? = nil) {
        self.screen = screen
        self.session = session
        self.live = nil
        self.platform = platform
        if case .mail(let environment) = screen { startSystemFeatures(environment) }
    }

    private func startSystemFeatures(_ environment: AppEnvironment) {
        if let platform { environment.installPlatform(platform()) }
        environment.runLaunchTasks()
        if platform != nil { environment.welcomeGuide.presentIfFirstRun() }
    }

    init(live: LiveBackend, platform: (@MainActor () -> SystemPlatform)? = nil) {
        self.live = live
        self.platform = platform
        self.screen = .launching
        switch live.initialStep() {
        case .session(let account):
            proceed(account, backend: live)
        case .signIn(let hint, let notice):
            showSignIn(backend: live, loginHint: hint, notice: notice)
        case .needsWriteAccess(let account):
            showSignIn(backend: live, loginHint: account.email, notice: LiveBackend.writeAccessNotice)
        }
    }

    private func showSignIn(backend: LiveBackend, loginHint: String, notice: String?) {
        let model = SignInModel(accounts: backend.accounts, loginHint: loginHint, notice: notice)
        model.onSignedIn = { [weak self] id in self?.signedIn(id) }
        screen = .signIn(model)
    }

    private func signedIn(_ id: AccountID) {
        guard let live, let account = live.account(id) else {
            screen = .notice(StartupProblem(title: "Mail couldn't finish signing in",
                                            message: "Your sign-in is saved. Quit and open Mail again to continue."))
            return
        }
        proceed(account, backend: live)
    }

    private func proceed(_ account: AccountItem, backend: LiveBackend) {
        startSession(account, backend: backend)
    }

    func shutdown() async {
        await session?.shutdown()
    }

    private func startSession(_ account: AccountItem, backend: LiveBackend) {
        do {
            let session = try backend.makeSession(for: account)
            self.session = session
            backend.accounts.attach(link(for: session))
            screen = .mail(session.environment)
            deepLinks.readinessChanged()
            startSystemFeatures(session.environment)
            Task { await session.start() }
        } catch let error as AccountSetupError where error.kind == .clientMissing {
            showSignIn(backend: backend, loginHint: account.email, notice: error.message)
        } catch {
            screen = .notice(StartupProblem(
                title: "Mail couldn't start syncing",
                message: "Mail opened but couldn't start syncing \(account.email). " + CompositionRoot.syncStartMessage(error),
                details: CompositionRoot.detailCode(error),
                action: (title: "Sign in again", run: { [weak self] in
                    self?.showSignIn(backend: backend, loginHint: account.email, notice: nil)
                })))
        }
    }

    private func link(for session: SyncSession) -> LiveAccountManager.SessionLink {
        LiveAccountManager.SessionLink(
            engine: session.engine,
            forgetInWindow: { [weak environment = session.environment, weak session] account in
                if let session, session.account == account { await session.calendar?.forget() }
                await session?.calendarConnections?.forget(account)
                guard let environment else { return }
                await environment.ai?.clearCache()
                await environment.ai?.forgetTraces(for: account)
                await environment.system.removeAccount(account)
            },
            removed: { [weak self] account in await self?.accountRemoved(account) })
    }

    static let signedOutNotice = "Signed out and removed from this Mac; nothing changed in Gmail."

    private func accountRemoved(_ account: AccountID) async {
        guard let live, case .mail(let environment) = screen else { return }
        let remaining = ((try? live.store.accounts()) ?? []).filter { $0.status != .removing && $0.status != .disabled }
        guard remaining.isEmpty else { return }
        live.accounts.attach(nil)
        environment.system.stopAll()
        let ending = session
        session = nil
        showSignIn(backend: live, loginHint: "", notice: Self.signedOutNotice)
        await ending?.stop()
    }
}
