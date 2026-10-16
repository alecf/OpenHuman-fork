import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    CalendarDateMentions.calendar(newYork).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

@MainActor
private struct ConnectedFixFixture {
    static let home = "sam.home@example.org"
    let env: AppEnvironment
    let store: FakeMailStore
    let work: FakeCalendar
    let homeCalendar: FakeCalendar
    let connections: FakeCalendarConnections
    let workID: AccountID
    let homeID: AccountID
    var workEmail: String { FakeCorpus.me.email }

    static func make(connected: Set<String> = []) async throws -> ConnectedFixFixture {
        let corpus = FakeCorpus.make(threadCount: 3, now: at(10, 10, 9))
        let work = FakeCalendar(events: [CalendarEvent(id: "w1", title: "Work standup", start: at(10, 10, 10),
                                                       end: at(10, 10, 10, 30))],
                                info: CalendarProviderInfo(name: "Google Calendar", account: FakeCorpus.me.email))
        let home = FakeCalendar(events: [CalendarEvent(id: "h1", title: "Dentist", start: at(10, 10, 14),
                                                       end: at(10, 10, 15))],
                                info: CalendarProviderInfo(name: "Google Calendar", account: Self.home))
        let connections = FakeCalendarConnections(connected: connected,
                                                  providers: [FakeCorpus.me.email: work, Self.home: home],
                                                  followsConnection: true, windowAccount: FakeCorpus.me.email)
        let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), calendarConnections: connections)
        let store = try #require(env.data as? FakeMailStore)
        store.enqueueSignIn(.succeed(email: Self.home, displayName: nil))
        let homeID = try await store.addAccount(loginHint: nil)
        return ConnectedFixFixture(env: env, store: store, work: work, homeCalendar: home, connections: connections,
                                   workID: corpus.account.id, homeID: homeID)
    }

    func thread(_ account: AccountID) -> ThreadKey {
        ThreadKey(account: account, rowID: account == workID ? 1 : 9_001, gmailThreadID: GmailThreadID("t\(account.rawValue)"))
    }

    func sidebar() throws -> CalendarSidebarModel {
        let model = try #require(env.calendarSidebar)
        model.timeZone = newYork
        model.now = { at(10, 10, 9) }
        model.loadText = { _ in CalendarThreadText(subject: "Planning", texts: ["Planning", "October 10, 2026 at 4:00 PM"],
                                                   participants: []) }
        model.setVisible(true)
        return model
    }

    func settings() async throws -> CalendarSettingsModel {
        let settings = CalendarSettingsModel(environment: env)
        settings.start()
        await eventually { settings.calendarInboxes.count == 2 && settings.calendarInboxes.allSatisfy { $0.state != nil } }
        return settings
    }

    func titles(_ model: CalendarSidebarModel) -> [String] { model.days.flatMap(\.events).map(\.title) }
}

@MainActor
@Suite struct CalendarConnectedFixTests {
    @Test func aCalendarConnectedWhileMailRunsReachesEveryConsumerAtOnce() async throws {
        let f = try await ConnectedFixFixture.make()
        let window = try #require(f.env.calendar)
        #expect(f.env.modules.modules.contains(.calendar) && f.env.calendarSidebar != nil)
        #expect(window.info.createRefusal == RoutedCalendarProvider.noneConnected)
        await #expect(throws: CalendarError.notConfigured) { _ = try await window.events(from: at(10, 10), to: at(10, 11)) }
        let sidebar = try f.sidebar()
        await sidebar.show(thread: f.thread(f.workID))
        await eventually { sidebar.connectionStates.count == 2 }
        #expect(sidebar.days.isEmpty && sidebar.calendarNote == CalendarSidebarModel.notConnected(f.workEmail))
        #expect(sidebar.connectTitle == "Connect calendar for \(f.workEmail)")
        let settings = try await f.settings()
        #expect(settings.createStatus == CalendarSettingsModel.needsConnectedText && !settings.canCreateEvents)
        #expect(settings.createConnectOffers.map(\.account.email) == [f.workEmail, ConnectedFixFixture.home])
        #expect(settings.createConnectOffers.map(CalendarSettingsModel.connectTitle)
                    == ["Connect calendar for \(f.workEmail)", "Connect calendar for \(ConnectedFixFixture.home)"])

        let workRow = try #require(settings.calendarInboxes.first { $0.id == f.workID })
        await settings.connect(workRow)
        await eventually { f.titles(sidebar) == ["Work standup"] }
        #expect(sidebar.calendarNote == nil && sidebar.connectTitle == nil)
        await eventually { settings.canCreateEvents }
        #expect(settings.createStatus.contains(f.workEmail) && settings.createStatus.hasPrefix("Events can be created"))
        #expect(settings.createConnectOffers.map(\.account.email) == [ConnectedFixFixture.home], "Connect for the other")

        #expect(window.info.account == f.workEmail && window.info.createRefusal == nil)
        #expect(try await window.events(from: at(10, 10), to: at(10, 11)).map(\.title) == ["Work standup"])

        await sidebar.beginDraft(for: f.thread(f.workID))
        #expect(sidebar.createRefusal == nil)
        #expect(await sidebar.createEvent())
        #expect(f.work.createCalls == 1 && f.homeCalendar.createCalls == 0)

        let entries = await f.env.calendarDiagnostics()
        #expect(entries.map(\.status) == ["connected", "disconnected"])
        withExtendedLifetime(f) {}
    }

    @Test func theWindowsCalendarForwardsTheFullEditPatch() async throws {
        let f = try await ConnectedFixFixture.make(connected: [FakeCorpus.me.email])
        let window = try #require(f.env.calendar)
        let standup = try #require(f.work.allEvents.first)
        var patch = CalendarEventPatch()
        patch.title = "Retitled"
        let saved = try await window.patchEvent(standup, with: patch, scope: .thisEvent, sendUpdates: .none)
        #expect(saved.title == "Retitled")
        #expect(f.work.calls.contains { if case .patch = $0 { true } else { false } })
        withExtendedLifetime(f) {}
    }

    @Test func twoAccountsEachFollowTheirOwnConnection() async throws {
        let f = try await ConnectedFixFixture.make()
        let sidebar = try f.sidebar()
        await sidebar.show(thread: f.thread(f.homeID))
        await eventually { sidebar.connectionStates.count == 2 }
        #expect(sidebar.calendarNote == CalendarSidebarModel.notConnected(ConnectedFixFixture.home))
        #expect(sidebar.connectTitle == "Connect calendar for \(ConnectedFixFixture.home)")

        await sidebar.connectShownCalendar()
        #expect(sidebar.connectError == nil)
        #expect(f.connections.connection(ConnectedFixFixture.home).connectCalls == 1)
        #expect(f.connections.connection(f.workEmail).connectCalls == 0, "only that account's consent")
        #expect(f.titles(sidebar) == ["Dentist"] && sidebar.calendarNote == nil)
        #expect(f.env.calendar?.info.account == ConnectedFixFixture.home)

        let homeReads = f.homeCalendar.readCalls
        await sidebar.show(thread: f.thread(f.workID))
        #expect(sidebar.days.isEmpty && sidebar.calendarNote == CalendarSidebarModel.notConnected(f.workEmail))
        #expect(f.homeCalendar.readCalls == homeReads)

        try await f.connections.connection(f.workEmail).connect()
        await eventually { f.titles(sidebar) == ["Work standup"] }
        #expect(f.env.calendar?.info.account == f.workEmail, "the window's own account first once it is connected")
        withExtendedLifetime(f) {}
    }

    @Test func failureStatesSayWhyInsteadOfHiding() async throws {
        let f = try await ConnectedFixFixture.make(connected: [FakeCorpus.me.email])
        let sidebar = try f.sidebar()
        await sidebar.show(thread: f.thread(f.workID))
        #expect(f.titles(sidebar) == ["Work standup"])
        await eventually { sidebar.connectionStates.count == 2 }

        f.connections.connection(f.workEmail).expire()
        await eventually { sidebar.calendarNote == CalendarSidebarModel.needsSignInAgain(f.workEmail) }
        #expect(sidebar.days.isEmpty && sidebar.connectIsReconnect)
        #expect(sidebar.connectTitle == "Reconnect calendar for \(f.workEmail)")
        let settings = try await f.settings()
        await eventually { settings.createConnectOffers.count == 2 }
        #expect(settings.createStatus == CalendarSettingsModel.needsConnectedText)
        #expect(settings.createConnectOffers.map(CalendarSettingsModel.connectTitle).first
                    == "Reconnect calendar for \(f.workEmail)")

        let refused = "Google refused (HTTP 400, invalid_grant). Nothing was stored."
        f.connections.connection(f.workEmail).failure = refused
        await sidebar.connectShownCalendar()
        #expect(sidebar.connectError == refused && sidebar.calendarNote != nil)
        f.connections.connection(f.workEmail).failure = nil
        await sidebar.connectShownCalendar()
        #expect(sidebar.connectError == nil && f.titles(sidebar) == ["Work standup"])

        f.env.calendarEvents.forgetAll()
        f.work.failure = "The calendar is offline."
        await sidebar.refresh()
        #expect(sidebar.state == .failed("Couldn't load events: The calendar is offline."))
        withExtendedLifetime(f) {}
    }

    @Test func schedulingShowsNoChipsWithoutAConnectedCalendar() async throws {
        let f = try await ConnectedFixFixture.make()
        let assistant = try #require(f.env.scheduling)
        let thread = f.thread(f.workID)
        let key = MessageKey(account: f.workID, rowID: 1, gmailMessageID: GmailMessageID("m1"))
        assistant.timeZone = newYork
        assistant.now = { at(10, 10, 9) }
        assistant.language = nil
        assistant.loadMessage = { _ in
            SchedulingMessage(key: key, subject: "Re: Sync", senderName: nil, sentAt: at(10, 10, 8),
                              text: "How about 1pm tomorrow?", isFromMe: false)
        }
        await assistant.analyze(thread)
        #expect(assistant.status[thread] == nil && assistant.suggestions(for: thread).isEmpty)
        #expect(f.work.readCalls == 0 && f.homeCalendar.readCalls == 0)
        withExtendedLifetime(f) {}
    }

    @Test func theFeedbackSnapshotListsEachAccountsCalendarWithoutAnAddress() async throws {
        let f = try await ConnectedFixFixture.make(connected: [FakeCorpus.me.email])
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("oh-calfix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let suite = "dev.openhuman.tests.calfix.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DevFeedbackCenter(availability: .devTools, settings: DevFeedbackSettings(defaults: defaults),
                                       paths: DevFeedbackPaths(support: support), bundledChecklist: nil,
                                       now: { at(10, 10, 9) })
        center.host = FakeDevFeedbackHost()
        let window = MailWindowModel(environment: f.env)
        center.window = window
        let snapshot = await center.snapshot()
        let calendars = try #require(snapshot.calendars)
        #expect(calendars.map(\.index) == [1, 2])
        #expect(calendars.map(\.status) == ["connected", "disconnected"])
        #expect(calendars.map(\.canCreateEvents) == [true, false])
        let json = String(decoding: try DevFeedbackBundle.encoder.encode(snapshot), as: UTF8.self)
        #expect(json.contains("\"calendars\""))
        #expect(!json.contains(f.workEmail) && !json.contains(ConnectedFixFixture.home) && !json.contains("@"))

        let plain = MailWindowModel(environment: .fake(corpus: FakeCorpus.make(threadCount: 1, now: at(10, 10, 9))))
        center.window = plain
        #expect(await center.snapshot().calendars == nil)
        withExtendedLifetime((window, plain)) {}
    }

    @Test func aCalendarEntryCarriesScopeNamesFetchAgeAndCodesOnly() {
        let state = CalendarConnectionState(status: .connected, account: "robin@example.com", canCreateEvents: true,
                                            scopes: ["https://www.googleapis.com/auth/calendar.events",
                                                     "https://www.googleapis.com/auth/calendar.freebusy"],
                                            lastFetch: at(10, 10, 8, 58), lastFetchError: "server_503")
        let entry = DiagnosticsCalendarEntry(index: 2, state: state, now: at(10, 10, 9))
        #expect(entry.scopes == ["calendar.events", "calendar.freebusy"])
        #expect(entry.lastFetchAgeSeconds == 120 && entry.lastError == "server_503")
        var leaky = entry
        leaky.lastError = "robin@example.com refused"
        #expect(leaky.sanitized(DiagnosticsExporter.code).lastError == "<redacted>")
        #expect(DiagnosticsCalendarEntry(index: 1, state: nil).status == "unavailable")
    }
}
