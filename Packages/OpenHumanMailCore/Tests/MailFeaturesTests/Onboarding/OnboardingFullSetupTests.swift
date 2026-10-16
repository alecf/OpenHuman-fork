import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct FullSetupFixture {
    static let first = "robin.work@example.com"
    static let second = "robin.home@example.org"

    let store: FakeMailStore
    let calendars: FakeCalendarConnections
    let progress: InMemoryOnboardingProgress
    let accounts: any AccountManaging

    init(corpus: FakeCorpus? = nil, connected: Set<String> = [], liveConnectivity: Bool = false,
         accounts: ((FakeMailStore) -> any AccountManaging)? = nil, progress: OnboardingProgress = OnboardingProgress()) {
        let corpus = corpus ?? FakeCorpus.make(threadCount: 3)
        store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, liveConnectivity: liveConnectivity))
        calendars = FakeCalendarConnections(connected: connected)
        self.progress = InMemoryOnboardingProgress(progress)
        self.accounts = accounts?(store) ?? store
    }

    func model() -> OnboardingModel {
        OnboardingModel(store: progress, ports: OnboardingModel.Ports(
            data: store, accounts: accounts, ai: FakeAIOnboarding(), notifier: FakeSystemNotifier(),
            loginItem: FakeLoginItem(), calendars: calendars, settings: store))
    }

    func inboxes() async throws -> [Account] {
        for try await list in store.accounts() { return list }
        return []
    }

    func addInbox(_ email: String, to model: OnboardingModel) async throws {
        await model.go(to: .inboxes)
        await model.addAnotherInbox()
        #expect(model.step == .connectEmail)
        let signIn = try #require(model.emailSignIn)
        await eventually { signIn.canSignIn }
        store.enqueueSignIn(.succeed(email: email, displayName: nil))
        signIn.signIn()
        await eventually { model.step == .calendar && model.setupInbox?.email == email }
    }
}

@MainActor
struct OnboardingFullSetupTests {
    @Test func twoInboxesEachGetTheirEmailThenTheirOwnCalendarStep() async throws {
        let f = FullSetupFixture()
        let model = f.model()
        await model.enter()
        let first = try #require(try await f.inboxes().first)
        await model.next()
        #expect(model.step == .calendar && model.setupInbox?.id == first.id)
        #expect(model.title == "Connect calendar for \(first.email)")
        let firstCalendar = f.calendars.connection(first.email)
        #expect(firstCalendar.connectCalls == 0, "nothing is asked of Google until Connect calendar is pressed")
        #expect(model.setupCalendar?.canConnect == true)

        await model.connectCalendar()
        #expect(firstCalendar.connectCalls == 1 && firstCalendar.connectClients == [nil], "the inbox's own client")
        #expect(model.step == .inboxes)
        #expect(model.inboxRows.map(\.calendar) == [.connected] && model.inboxRows.map(\.email) == [.connected])

        try await f.addInbox(FullSetupFixture.second, to: model)
        #expect(model.title == "Connect calendar for \(FullSetupFixture.second)")
        #expect(f.calendars.connection(FullSetupFixture.second).connectCalls == 0,
                "the email sign-in never asked for the calendar")
        #expect(model.stepCountText == "Step 2 of 8")

        await model.skipCalendar()
        #expect(model.step == .inboxes)
        let second = try #require(try await f.inboxes().first { $0.email == FullSetupFixture.second })
        #expect(try await f.store.get(AppSettings.calendarSetupSkipped(second.id)) == true, "kept for that inbox")
        #expect(try await f.store.get(AppSettings.calendarSetupSkipped(first.id)) == false)
        let rows = model.inboxRows
        #expect(rows.map(\.account.email) == [first.email, FullSetupFixture.second])
        #expect(rows.map(\.calendar) == [.connected, .skipped])
        #expect(rows.map(\.email) == [.connected, .connected])
        #expect(rows[1].calendarText == "Calendar skipped for now" && rows[0].calendarText == "Calendar connected")
        #expect(f.calendars.connection(FullSetupFixture.second).connectCalls == 0)
    }

    @Test func quittingMidwayResumesOnTheSameStepAndInbox() async throws {
        let f = FullSetupFixture()
        func environment() -> AppEnvironment {
            AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store, isFake: false,
                           aiOnboarding: FakeAIOnboarding(), onboardingProgress: f.progress,
                           calendarConnections: f.calendars)
        }
        let launch = environment()
        launch.welcomeGuide.presentIfFirstRun()
        let model = try #require(launch.welcomeGuide.model)
        await model.enter()
        try await f.addInbox(FullSetupFixture.second, to: model)
        #expect(f.progress.load().step == .calendar && f.progress.load().isOpen)

        let relaunch = environment()
        relaunch.welcomeGuide.presentIfFirstRun()
        let resumed = try #require(relaunch.welcomeGuide.model, "an interrupted setup opens again by itself")
        await resumed.enter()
        #expect(resumed.step == .calendar && resumed.setupInbox?.email == FullSetupFixture.second)
        #expect(resumed.title == "Connect calendar for \(FullSetupFixture.second)")
        await resumed.connectCalendar()
        #expect(resumed.step == .inboxes && f.calendars.connection(FullSetupFixture.second).current.status == .connected)

        relaunch.welcomeGuide.dismiss()
        let third = environment()
        third.welcomeGuide.presentIfFirstRun()
        #expect(!third.welcomeGuide.isPresented, "closed on purpose: it does not come back by itself")
        third.welcomeGuide.present()
        #expect(third.welcomeGuide.model?.step == .inboxes, "Help › Show Welcome Guide still resumes")
    }

    @Test func aCalendarFailureLeavesTheInboxEmailAsItWas() async throws {
        let f = FullSetupFixture()
        let model = f.model()
        await model.go(to: .calendar)
        let before = try await f.inboxes()
        let inbox = try #require(before.first)
        let calendar = f.calendars.connection(inbox.email)
        calendar.failure = "Google didn't answer in time. Try again."
        await model.connectCalendar()
        #expect(model.step == .calendar, "stays, with the reason")
        #expect(model.setupCalendar?.errorMessage == "Google didn't answer in time. Try again.")
        #expect(model.setupCalendar?.isConnected == false && calendar.current.status == .disconnected)
        #expect(try await f.inboxes() == before, "the inbox, its health and its sign-in are untouched")
        #expect(model.inboxRows.first?.email == .connected)
        #expect(try await f.store.get(AppSettings.calendarSetupSkipped(inbox.id)) == false, "a failure is not a skip")

        calendar.failure = nil
        await model.connectCalendar()
        #expect(model.step == .inboxes && model.inboxRows.first?.calendar == .connected)
        #expect(model.setupCalendar?.errorMessage == nil)
    }

    @Test func theSummaryListsEveryInboxAndFixesWhatIsLeft() async throws {
        let corpus = FakeCorpus.small
        let work = corpus.mailboxes[0].account, personal = corpus.mailboxes[1].account
        let f = FullSetupFixture(corpus: corpus, connected: [work.email], liveConnectivity: true)
        try await f.store.set(AppSettings.calendarSetupSkipped(personal.id), true)
        f.store.setConnectivity(.online(syncing: true, lastSyncAt: nil), for: work.id)
        f.store.setSyncProgress("Syncing 1,240 of 4,707", for: work.id)
        f.store.setConnectivity(.online(syncing: false, lastSyncAt: Date()), for: personal.id)
        let model = f.model()
        await model.go(to: .ready)
        await eventually { model.inboxRows.count == 2 && model.inboxRows[0].calendar == .connected }
        await eventually { model.inboxRows[0].syncLine == "Syncing 1,240 of 4,707" }
        await eventually { model.inboxRows[1].syncLine == "Up to date" }
        #expect(model.inboxRows[1].calendar == .skipped && model.inboxRows[1].calendarCanBeFixed)
        #expect(model.summaryLine == "One inbox has a step left; finish it here or later.")
        #expect(model.title == "All set")

        await model.fixCalendar(personal.id)
        #expect(model.step == .calendar && model.title == "Connect calendar for \(personal.email)")
        await model.connectCalendar()
        #expect(model.step == .ready, "back to the summary")
        #expect(model.inboxRows.allSatisfy { $0.isComplete })
        #expect(model.summaryLine == "All 2 inboxes are ready.")
        #expect(try await f.store.get(AppSettings.calendarSetupSkipped(personal.id)) == false)
    }

    @Test func anInboxThatNeedsSigningInCanBeFixedFromTheSummary() async throws {
        let f = FullSetupFixture(liveConnectivity: true)
        let inbox = try #require(try await f.inboxes().first)
        f.store.setConnectivity(.needsReauth, for: inbox.id)
        let model = f.model()
        await model.go(to: .ready)
        await eventually { model.inboxRows.first?.email == .needsSignIn }
        #expect(model.inboxRows.first?.emailText == "Email needs you to sign in again")
        f.store.enqueueSignIn(.fail)
        await model.signInAgain(inbox.id)
        #expect(model.fixError == "Sign-in failed. Try again.")
        await model.signInAgain(inbox.id)
        #expect(model.fixError == nil)
        await eventually { model.inboxRows.first?.email == .connected }
    }

    @Test func withoutCalendarConnectionsTheStepSaysSoAndMovesOn() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3), options: .init(remoteAck: .immediate))
        let model = OnboardingModel(store: InMemoryOnboardingProgress(), ports: OnboardingModel.Ports(
            data: store, accounts: store, ai: FakeAIOnboarding(), notifier: FakeSystemNotifier(),
            loginItem: FakeLoginItem()))
        await model.go(to: .calendar)
        #expect(model.setupCalendar?.canConnect == false)
        #expect(model.inboxRows.first?.calendar == .unavailable && model.inboxRows.first?.isComplete == true)
        await model.connectCalendar()
        #expect(model.step == .calendar, "nothing to connect")
        await model.next()
        #expect(model.step == .inboxes)
    }

    @Test func theCalendarStepCanUseAnotherGoogleClient() async throws {
        let f = FullSetupFixture(accounts: { TwoClientAccounts(store: $0) })
        let model = f.model()
        await model.go(to: .calendar)
        #expect(model.showsCalendarClientChoice)
        #expect(model.calendarClientChoices.map(\.title)
            == ["This inbox's Google client (…aaaa1111)", "Google client …bbbb2222"], "no secret-less client offered")
        #expect(model.calendarClientChoice == nil)
        model.calendarClientChoice = "key-b"
        await model.connectCalendar()
        let inbox = try #require(try await f.inboxes().first)
        #expect(f.calendars.connection(inbox.email).connectClients == ["key-b"])
        #expect(model.step == .inboxes)
        await model.fixCalendar(inbox.id)
        #expect(model.calendarClientChoice == nil, "every visit starts from the inbox's own client")
    }

    @Test func aConnectionWithoutClientChoiceRefusesAnotherClient() async {
        struct Plain: CalendarConnecting {
            func connectionStates() -> AsyncStream<CalendarConnectionState> { AsyncStream { $0.finish() } }
            func connect() async throws {}
            func disconnect() async throws {}
        }
        await #expect(throws: CalendarError.self) { try await Plain().connect(client: "key-b") }
        await #expect(throws: Never.self) { try await Plain().connect(client: nil) }
    }

    @Test func progressSavedByAnEarlierBuildStillLoads() throws {
        let old = Data(#"{"step":"secondAccount","completed":false,"skipped":["secondAccount","look"],"aiAnswered":true,"shown":true}"#.utf8)
        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: old)
        #expect(progress == OnboardingProgress(step: .inboxes, skipped: [.inboxes, .look], aiAnswered: true, shown: true))
        #expect(progress.setupAccount == nil && !progress.isOpen)
        let saved = OnboardingProgress(step: .calendar, shown: true, setupAccount: AccountID(7), isOpen: true)
        #expect(try JSONDecoder().decode(OnboardingProgress.self, from: JSONEncoder().encode(saved)) == saved)
    }

    @Test func settingsCalendarConnectsTheOtherInboxes() async throws {
        let corpus = FakeCorpus.small
        let work = corpus.mailboxes[0].account, personal = corpus.mailboxes[1].account
        let store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate))
        let calendars = FakeCalendarConnections()
        try await store.set(AppSettings.calendarSetupSkipped(personal.id), true)
        let env = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                 calendarConnection: calendars.connection(work.email), calendarConnections: calendars)
        let page = CalendarSettingsModel(environment: env)
        page.start()
        await eventually { page.connection != nil && page.otherInboxes.count == 1 }
        let other = try #require(page.otherInboxes.first)
        #expect(other.account.email == personal.email && CalendarSettingsModel.status(other) == "Off.")
        await page.setConnected(true, inbox: other)
        #expect(other.isConnected && CalendarSettingsModel.status(other) == "Connected.")
        #expect(try await store.get(AppSettings.calendarSetupSkipped(personal.id)) == false)
        #expect(calendars.connection(work.email).connectCalls == 0, "the window's own switch is untouched")
        await page.setConnected(false, inbox: other)
        #expect(!other.isConnected && calendars.connection(personal.email).disconnectCalls == 1)
    }
}

private struct TwoClientAccounts: AccountManaging {
    let store: FakeMailStore

    func accounts() -> AsyncThrowingStream<[Account], Error> { store.accounts() }
    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> { store.oauthClientStatus() }
    func importOAuthClient(json: Data) async throws { try await store.importOAuthClient(json: json) }
    func oauthClients() async -> [OAuthClientSummary] {
        [OAuthClientSummary(id: "key-a", shortID: "aaaa1111", isDefault: true, isSelected: true, hasSecret: true),
         OAuthClientSummary(id: "key-b", shortID: "bbbb2222", isDefault: false, isSelected: false, hasSecret: true),
         OAuthClientSummary(id: "key-c", shortID: "cccc3333", isDefault: false, isSelected: false, hasSecret: false)]
    }
    func selectOAuthClient(_ id: OAuthClientSummary.ID?) async throws {}
    func oauthClientShortID(for account: AccountID) async -> String? { "aaaa1111" }
    func addAccount(loginHint: String?) async throws -> AccountID { try await store.addAccount(loginHint: loginHint) }
    func reauthorize(_ account: AccountID) async throws { try await store.reauthorize(account) }
}
