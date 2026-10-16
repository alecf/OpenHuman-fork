import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

extension SweepTheme {
    static let lightAndDark: [SweepTheme] = Array(builtIns.prefix(2))
}

private let firstRunWindowSize = NSSize(width: 960, height: 640)

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func signInStates(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let cases: [(String, OAuthClientStatus, String?, Bool)] = [
            ("first-run-sign-in", .configured(source: .environment), nil, false),
            ("first-run-sign-in-more-options", .configured(source: .environment), nil, false),
            ("first-run-sign-in-no-client", .missing, nil, false),
            ("first-run-sign-in-no-client-more-options", .missing, nil, false),
            ("first-run-sign-in-setup-steps", .missing, nil, false),
            ("first-run-sign-in-own-client", .configured(source: .file), nil, false),
            ("first-run-sign-in-browser", .configured(source: .environment), nil, true),
            ("first-run-sign-in-signed-out", .configured(source: .environment),
             "Signed out and removed from this Mac; nothing changed in Gmail.", false),
        ]
        for (screen, status, notice, waits) in cases {
            let accounts = OnboardingSweepAccounts(status: status, waits: waits)
            let model = SignInModel(accounts: accounts, notice: notice)
            await model.run()
            if waits {
                model.signIn()
                try await until { model.phase == .signingIn }
            }
            if screen == "first-run-sign-in-setup-steps" {
                model.openClientGuide()
                model.clientGuide.toggle(GoogleClientGuide.steps[0])
            }
            if screen.hasSuffix("-more-options") || screen == "first-run-sign-in-own-client" {
                model.toggleMoreOptions()
            }
            if screen == "first-run-sign-in-more-options" { model.toggleAccessInfo() }
            if screen == "first-run-sign-in-own-client" { model.toggleOwnClient() }
            let window = sweepStandaloneWindow(SignInView(model: model, theme: store.resolved.tokens), store: store,
                                               size: firstRunWindowSize)
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: screen, theme: theme)
            if screen == "first-run-sign-in-setup-steps" {
                let tall = sweepStandaloneWindow(SignInView(model: model, theme: store.resolved.tokens), store: store,
                                                 size: NSSize(width: firstRunWindowSize.width, height: 1300))
                defer { tall.orderOut(nil) }
                try await sweepShoot(tall, screen: "first-run-sign-in-setup-steps-all", theme: theme)
            }
            model.cancel()
        }
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func welcomeGuide(_ theme: SweepTheme) async throws {
        let themes = theme.makeStore()
        let data = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate, liveConnectivity: true))
        let account = try await Self.firstAccount(data)
        data.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: account)
        data.setSyncProgress("Syncing 1,240 of 4,707", for: account)
        for step in OnboardingStep.allCases {
            let model = OnboardingModel(store: InMemoryOnboardingProgress(), ports: OnboardingModel.Ports(
                data: data, accounts: data, ai: FakeAIOnboarding(), notifier: FakeSystemNotifier(),
                loginItem: FakeLoginItem(), calendars: FakeCalendarConnections(), settings: data))
            await model.go(to: step)
            if step == .ready { try await until(timeout: .seconds(60)) { model.syncLine != nil } }
            if step == .connectEmail { try await until(timeout: .seconds(60)) { model.emailSignIn?.canSignIn == true } }
            let window = sweepStandaloneWindow(WelcomeGuideView(model: model, onClose: {}), store: themes,
                                               size: NSSize(width: 720, height: 520))
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: "first-run-guide-\(step.rawValue)", theme: theme)
        }
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func fullSetup(_ theme: SweepTheme) async throws {
        let themes = theme.makeStore()
        let data = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate, liveConnectivity: true))
        let accounts = try await Self.accounts(data)
        let work = try #require(accounts.first), personal = try #require(accounts.dropFirst().first)
        data.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: work.id)
        data.setSyncProgress("Syncing 1,240 of 4,707", for: work.id)
        data.setConnectivity(.online(syncing: false, lastSyncAt: Date()), for: personal.id)
        try await data.set(AppSettings.calendarSetupSkipped(personal.id), true)
        let calendars = FakeCalendarConnections(connected: [work.email])

        func model(_ accounts: any AccountManaging = data) -> OnboardingModel {
            OnboardingModel(store: InMemoryOnboardingProgress(), ports: OnboardingModel.Ports(
                data: data, accounts: accounts, ai: FakeAIOnboarding(), notifier: FakeSystemNotifier(),
                loginItem: FakeLoginItem(), calendars: calendars, settings: data))
        }
        func shoot(_ model: OnboardingModel, _ screen: String) async throws {
            let window = sweepStandaloneWindow(WelcomeGuideView(model: model, onClose: {}), store: themes,
                                               size: NSSize(width: 720, height: 520))
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: screen, theme: theme)
        }

        let clients = model(SweepTwoClients(store: data))
        await clients.fixCalendar(personal.id)
        try await shoot(clients, "first-run-guide-calendar-clients")

        let failing = model()
        await failing.fixCalendar(personal.id)
        calendars.connection(personal.email).failure = "Google didn't answer in time. Try again."
        await failing.connectCalendar()
        try await shoot(failing, "first-run-guide-calendar-error")
        calendars.connection(personal.email).failure = nil

        let list = model()
        await list.go(to: .inboxes)
        try await until(timeout: .seconds(60)) { list.inboxRows.count == 2 && list.inboxRows[0].calendar == .connected }
        try await shoot(list, "first-run-guide-inboxes-two")

        let summary = model()
        await summary.go(to: .ready)
        try await until(timeout: .seconds(60)) {
            summary.inboxRows.count == 2 && summary.inboxRows[0].syncLine != nil && summary.inboxRows[1].syncLine != nil
        }
        try await shoot(summary, "first-run-guide-ready-two")
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func calendarOtherInboxes(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let data = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let accounts = try await Self.accounts(data)
        let work = try #require(accounts.first)
        let calendars = FakeCalendarConnections(connected: [work.email])
        let environment = AppEnvironment(data: data, commands: data, accounts: data, settings: data, isFake: true,
                                         calendarConnection: calendars.connection(work.email),
                                         calendarConnections: calendars)
        let window = sweepStandaloneWindow(CalendarSettingsPage(environment: environment), store: store,
                                           size: NSSize(width: 760, height: 760))
        defer { window.orderOut(nil) }
        try await sweepShoot(window, screen: "first-run-settings-calendar-inboxes", theme: theme, settle: .milliseconds(700))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func accountsGoogleSteps(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let environment = SweepWindow.environment()
        let window = sweepStandaloneWindow(AccountsSettingsPage(environment: environment), store: store,
                                           size: NSSize(width: 760, height: 760))
        defer { window.orderOut(nil) }
        try await sweepShoot(window, screen: "first-run-settings-accounts", theme: theme, settle: .milliseconds(700))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func firstSync(_ theme: SweepTheme) async throws {
        do {
            let w = try await SweepWindow.make(SweepWindow.environment(liveConnectivity: true), theme: theme)
            defer { w.close() }
            let store = try #require(w.environment.data as? FakeMailStore)
            let account = try #require(w.router.accounts.first?.account)
            let inbox = try await w.environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 5000)
            store.removeThreads(Set(inbox.rows.map(\.id)))
            for item in w.router.accounts { store.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: item.id) }
            store.setSyncProgress("Syncing 0 of 4,707", for: account.id)
            try await until { w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == true }
            try await sweepShoot(w.window, screen: "first-run-sync-empty", theme: theme, settle: .milliseconds(700))
        }
        do {
            let w = try await SweepWindow.make(SweepWindow.environment(liveConnectivity: true), theme: theme)
            defer { w.close() }
            let store = try #require(w.environment.data as? FakeMailStore)
            for item in w.router.accounts { store.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: item.id) }
            let account = try #require(w.router.accounts.first?.id)
            store.setSyncProgress("Syncing 1,240 of 4,707", for: account)
            try await until { w.environment.status.progress[account] != nil }
            try await sweepShoot(w.window, screen: "first-run-sync-filling", theme: theme)
        }
    }

    private static func accounts(_ data: FakeMailStore) async throws -> [Account] {
        for try await accounts in data.accounts() { return accounts }
        return []
    }

    private static func firstAccount(_ data: FakeMailStore) async throws -> AccountID {
        for try await accounts in data.accounts() {
            if let first = accounts.first { return first.id }
        }
        throw MailPortError.unavailable("the fake corpus has an account")
    }
}

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func calendarParityTwoAccounts(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let data = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        if try await Self.accounts(data).count < 2 {
            data.enqueueSignIn(.succeed(email: "robin.home@example.org", displayName: nil))
            _ = try await data.addAccount(loginHint: nil)
        }
        let accounts = try await Self.accounts(data)
        let work = try #require(accounts.first), home = try #require(accounts.dropFirst().first)
        let calendars = FakeCalendarConnections(connected: [work.email, home.email])
        calendars.connection(home.email).expire()
        let environment = AppEnvironment(data: data, commands: data, accounts: SweepTwoClients(store: data), settings: data,
                                         isFake: true, calendarConnection: calendars.connection(work.email),
                                         calendarConnections: calendars)
        let window = sweepStandaloneWindow(CalendarSettingsPage(environment: environment), store: store,
                                           size: NSSize(width: 760, height: 1100))
        defer { window.orderOut(nil) }
        try await sweepShoot(window, screen: "settings-calendar-two-accounts", theme: theme, settle: .milliseconds(700))
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func signInWaitingPanel(_ theme: SweepTheme) async throws {
        let store = theme.makeStore()
        let cases: [(String, PendingSignIn, Bool)] = [
            ("signin-waiting", FakeSignInBrowsing.sampleSignIn(), false),
            ("signin-waiting-calendar-remembered",
             FakeSignInBrowsing.sampleSignIn(purpose: .calendar, openedIn: "Beta Browser"), false),
            ("signin-waiting-link-copied", FakeSignInBrowsing.sampleSignIn(openFailed: true), true),
        ]
        for (screen, pending, showsLink) in cases {
            let port = FakeSignInBrowsing(pending: pending)
            if pending.openedIn != nil { port.remember("com.example.browser.beta", for: pending.account ?? "") }
            let model = SignInWaitingModel(port: port, clipboard: FakeSignInClipboard())
            model.start()
            try await until { model.pending != nil && !model.browsers.isEmpty }
            if showsLink {
                model.toggleLink()
                model.copyLink()
            }
            let window = sweepStandaloneWindow(SignInWaitingPanel(model: model), store: store,
                                               size: NSSize(width: SignInWaitingPanel.width, height: showsLink ? 520 : 360))
            defer { window.orderOut(nil) }
            try await sweepShoot(window, screen: screen, theme: theme)
            model.stop()
        }
    }
}

private struct OnboardingSweepAccounts: AccountManaging {
    let status: OAuthClientStatus
    var waits = false

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let status = status
        return AsyncStream { $0.yield(status); $0.finish() }
    }

    func importOAuthClient(json: Data) async throws {}

    func addAccount(loginHint: String?) async throws -> AccountID {
        if waits { try await Task.sleep(for: .seconds(3600)) }
        return AccountID(1)
    }
}

private struct SweepTwoClients: AccountManaging {
    let store: FakeMailStore

    func accounts() -> AsyncThrowingStream<[Account], Error> { store.accounts() }
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> { store.oauthClientStatus() }
    func importOAuthClient(json: Data) async throws {}
    func oauthClients() async -> [OAuthClientSummary] {
        [OAuthClientSummary(id: "key-a", shortID: "aaaa1111", isDefault: true, isSelected: true, hasSecret: true),
         OAuthClientSummary(id: "key-b", shortID: "bbbb2222", isDefault: false, isSelected: false, hasSecret: true)]
    }
    func oauthClientShortID(for account: AccountID) async -> String? { "aaaa1111" }
    func addAccount(loginHint: String?) async throws -> AccountID { try await store.addAccount(loginHint: loginHint) }
}
