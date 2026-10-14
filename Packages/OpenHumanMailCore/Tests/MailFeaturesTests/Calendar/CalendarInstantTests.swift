import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private let newYork = TimeZone(identifier: "America/New_York")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func at(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ tz: TimeZone = newYork) -> Date {
    CalendarDateMentions.calendar(tz).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private func event(_ id: String, _ start: Date, _ end: Date, title: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: title ?? id, start: start, end: end)
}

private let robin = CalendarProviderInfo(name: "Google Calendar", account: "robin@example.com")

private final class GatedCalendar: CalendarProviding, Sendable {
    let inner: FakeCalendar
    let readGate: TestGate?
    let createGate: TestGate?

    init(_ inner: FakeCalendar, readGate: TestGate? = nil, createGate: TestGate? = nil) {
        self.inner = inner
        self.readGate = readGate
        self.createGate = createGate
    }

    var info: CalendarProviderInfo { inner.info }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { try await inner.events(from: from, to: to) }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { try await inner.freeBusy(from: from, to: to) }
    func eventWindow(from: Date, to: Date) async throws -> CalendarEventWindow {
        let answer = try await inner.eventWindow(from: from, to: to)
        await readGate?.wait()
        return answer
    }
    func eventDelta(since token: String) async throws -> CalendarEventDelta {
        let answer = try await inner.eventDelta(since: token)
        await readGate?.wait()
        return answer
    }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        await createGate?.wait()
        return try await inner.createEvent(draft)
    }
    func deleteEvent(_ event: CalendarEvent) async throws { try await inner.deleteEvent(event) }
}

@MainActor
private final class Seen {
    var changes: [CalendarEventStoreChange] = []
}

@MainActor
private struct InstantFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let corpus: FakeCorpus
    let thread: ThreadKey

    init(events: [CalendarEvent] = [], info: CalendarProviderInfo? = nil, cache: InMemoryCalendarCache? = nil,
         connection: FakeCalendarConnection? = nil, gated: GatedCalendar? = nil) {
        corpus = .make(threadCount: 4, now: fixedNow)
        calendar = gated?.inner ?? info.map { FakeCalendar(events: events, info: $0) } ?? FakeCalendar(events: events)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate, safeMode: .normal),
                                  calendar: gated ?? calendar, calendarConnection: connection, calendarCache: cache)
        env.calendarEvents.timeZone = newYork
        thread = corpus.threads[0].row.id
    }

    var store: CalendarEventStore { env.calendarEvents }
    var key: CalendarCacheKey { CalendarCacheKey(provider: calendar.info) }

    func sidebar(_ text: CalendarThreadText? = nil) -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = newYork
        model.now = { at(10, 10, 9) }
        let shown = text
        model.loadText = { _ in shown }
        return model
    }

    func text(_ bodies: [String]) -> CalendarThreadText {
        CalendarThreadText(subject: "Planning", texts: ["Planning"] + bodies, participants: [])
    }

    func watch() -> Seen {
        let seen = Seen()
        store.observe { [weak seen] change in seen?.changes.append(change) }
        return seen
    }
}

@MainActor
@Suite struct CalendarInstantSidebarTests {
    @Test func theFirstShowReadsMinus14Plus45DaysInOneRequestAndFreeBusyComesFromTheSameEvents() async throws {
        let f = InstantFixture(events: [event("standup", at(10, 14, 10), at(10, 14, 11)),
                                        event("lunch", at(10, 15, 12), at(10, 15, 13))])
        let model = f.sidebar(f.text(["Can we meet on October 14, 2026 at 3:00 PM? Or October 15, 2026."]))
        await model.show(thread: f.thread)
        #expect(f.calendar.calls == [.window(from: at(9, 26), to: at(11, 24))], "one request for the whole window")
        #expect(model.state == .loaded && model.progress == nil && model.refreshNote == nil)
        #expect(model.days.map(\.start) == [at(10, 14), at(10, 15)])
        #expect(model.days[0].events.map(\.id) == ["standup"] && model.days[1].events.map(\.id) == ["lunch"])
        #expect(model.days[0].busy == [CalendarBusyInterval(start: at(10, 14, 10), end: at(10, 14, 11))],
                "free/busy of a covered day without a read of its own")
        #expect(model.days[0].free.first == CalendarBusyInterval(start: at(10, 14, 9), end: at(10, 14, 10)))
        #expect(f.store.ranges(f.key).map(\.start) == [at(9, 26)] && f.store.syncToken(f.key) == "fake-0")
    }

    @Test func movingInsideTheCoveredSpanIsDrawnAtOnceAndReadsNothing() async throws {
        let calendar = CalendarDateMentions.calendar(newYork)
        let days = (0...30).map { calendar.date(byAdding: .day, value: $0, to: at(10, 10))! }
        let f = InstantFixture(events: days.enumerated().map { offset, day in
            event("e\(offset)", day.addingTimeInterval(10 * 3_600), day.addingTimeInterval(11 * 3_600))
        })
        let model = f.sidebar()
        await model.show(thread: nil)
        let reads = f.calendar.readCalls
        #expect(reads == 1 && f.store.networkReads == 1)
        let clock = ContinuousClock()
        let started = clock.now
        var loads: [Task<Void, Never>] = []
        for step in 1...30 {
            let load = try #require(model.moveDayInstantly(by: 1))
            loads.append(load)
            #expect(model.days.first?.start == days[step])
            #expect(model.days.first?.events.map(\.id) == ["e\(step)"])
            #expect(model.state == .loaded && model.progress == nil)
        }
        for step in stride(from: 29, through: 0, by: -1) {
            loads.append(try #require(model.moveDayInstantly(by: -1)))
            #expect(model.days.first?.events.map(\.id) == ["e\(step)"])
        }
        let elapsed = clock.now - started
        for load in loads { await load.value }
        #expect(f.calendar.readCalls == reads, "zero network calls inside the covered span")
        #expect(f.store.networkReads == 1)
        #expect(elapsed < .seconds(2), "60 moves drawn from memory")
    }

    @Test func aRefreshReadsOnlyWhatChangedAndOnlyTheChangedIDsAreTold() async throws {
        let f = InstantFixture(events: [event("a", at(10, 14, 9), at(10, 14, 10)), event("b", at(10, 14, 13), at(10, 14, 14)),
                                        event("d", at(10, 15, 9), at(10, 15, 10))])
        let model = f.sidebar()
        await model.show(day: at(10, 14))
        let untouched = try #require(model.days.first?.events.first)
        let seen = f.watch()
        f.calendar.update(event("b", at(10, 14, 15), at(10, 14, 16), title: "b moved"))
        f.calendar.add(event("c", at(10, 14, 17), at(10, 14, 18)))
        f.calendar.remove(id: "d")
        await model.refresh()
        #expect(f.calendar.calls.last == .changes(token: "fake-0"), "the changes since the window's token, nothing else")
        #expect(f.store.syncToken(f.key) == "fake-3")
        let changes = seen.changes.filter { !$0.changedIDs.isEmpty }
        #expect(changes.count == 1)
        #expect(changes.first?.inserted == ["c"] && changes.first?.updated == ["b"] && changes.first?.removed == ["d"])
        #expect(model.days.first?.events.map(\.id) == ["a", "b", "c"])
        #expect(model.days.first?.events.first == untouched, "an unchanged event keeps its identity and value")
        seen.changes = []
        await model.refresh()
        #expect(seen.changes.allSatisfy { $0.changedIDs.isEmpty }, "nothing changed: nothing to redraw")
    }

    @Test func anExpiredTokenDropsTheCacheAndReadsTheWindowAgainInOneDiff() async throws {
        let f = InstantFixture(events: [event("a", at(10, 14, 9), at(10, 14, 10)), event("d", at(10, 15, 9), at(10, 15, 10))])
        let model = f.sidebar()
        await model.show(day: at(10, 14))
        let seen = f.watch()
        f.calendar.remove(id: "d")
        f.calendar.expireTokens()
        await model.refresh()
        #expect(Array(f.calendar.calls.suffix(2)) == [.changes(token: "fake-0"), .window(from: at(9, 26), to: at(11, 24))])
        #expect(f.store.record(f.key, id: "d") == nil && f.store.syncToken(f.key) == "fake-1")
        let changes = seen.changes.filter { !$0.changedIDs.isEmpty }
        #expect(changes.count == 1 && changes.first?.removed == ["d"] && changes.first?.inserted.isEmpty == true,
                "the views see one diff, never an empty day in between")
        #expect(model.days.first?.events.map(\.id) == ["a"] && model.state == .loaded)
    }

    @Test func aCreateShowsAtOnceAndTheRefreshReconcilesIt() async throws {
        let gate = TestGate()
        let gated = GatedCalendar(FakeCalendar(), createGate: gate)
        let f = InstantFixture(gated: gated)
        let model = f.sidebar(f.text(["Lunch on October 15, 2026 at 12:30 PM?"]))
        await model.show(thread: f.thread)
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.attendees.isEmpty == true, "created at once (no undo window)")
        let creating = Task { await model.createEvent() }
        await eventually { model.days.first?.events.contains { $0.id.hasPrefix("local-") } == true }
        #expect(f.calendar.createCalls == 0, "drawn before the calendar answered")
        gate.release()
        #expect(await creating.value)
        #expect(model.days.first?.events.map(\.id) == ["fake-event-1"], "the placeholder is replaced by the answer")
        #expect(f.calendar.calls.contains(.changes(token: "fake-0")), "the refresh after the write reconciles")
        #expect(f.store.record(f.key, id: "fake-event-1")?.etag == "v1", "the calendar's version now")
    }

    @Test func overlappingRefreshesOfOneCalendarShareOneRead() async throws {
        let gate = TestGate()
        let inner = FakeCalendar(events: [event("a", at(10, 14, 9), at(10, 14, 10))])
        let gated = GatedCalendar(inner, readGate: gate)
        let store = CalendarEventStore(timeZone: newYork)
        let key = CalendarEventStore.key(for: gated)
        let calendar = CalendarDateMentions.calendar(newYork)
        let visible = DateInterval(start: at(10, 14), end: at(10, 15))
        let now = at(10, 10, 9)
        async let one: Void = store.revalidate(key, provider: gated, visible: visible, today: now, calendar: calendar,
                                               now: now, force: true)
        async let two: Void = store.revalidate(key, provider: gated, visible: visible, today: now, calendar: calendar,
                                               now: now, force: true)
        async let three: Void = store.ensure(key, provider: gated, from: visible.start, to: visible.end, today: now,
                                             calendar: calendar, now: now)
        await eventually { inner.readCalls == 1 }
        gate.release()
        _ = await (one, two, three)
        #expect(inner.readCalls == 1 && store.networkReads == 1, "single flight per calendar")
        #expect(store.events(key, from: visible.start, to: visible.end)?.map(\.id) == ["a"])
    }

    @Test func recurringInstancesAndDeclinedEventsDiffOneByOne() async throws {
        let f = InstantFixture()
        for day in 14...16 {
            f.calendar.add(event("standup_202610\(day)", at(10, day, 9), at(10, day, 9, 15)), series: "standup")
        }
        let model = f.sidebar()
        await model.show(day: at(10, 15))
        #expect(model.days.first?.events.map(\.id) == ["standup_20261015"])
        #expect(f.store.record(f.key, id: "standup_20261014")?.recurringEventID == "standup")
        let seen = f.watch()
        f.calendar.remove(id: "standup_20261015")
        f.calendar.decline(id: "standup_20261016")
        await model.refresh()
        let changes = seen.changes.filter { !$0.changedIDs.isEmpty }
        #expect(changes.first?.removed == ["standup_20261015"] && changes.first?.updated == ["standup_20261016"])
        #expect(model.days.first?.events.isEmpty == true)
        #expect(f.store.record(f.key, id: "standup_20261016")?.declinedByMe == true)
        let wide = DateInterval(start: at(10, 14), end: at(10, 18))
        #expect(f.store.events(f.key, from: wide.start, to: wide.end)?.map(\.id) == ["standup_20261014"])
        #expect(f.store.events(f.key, from: wide.start, to: wide.end, includeDeclined: true)?.map(\.id)
                == ["standup_20261014", "standup_20261016"])
        #expect(f.store.events(f.key, from: wide.start, to: wide.end, includeDeclined: true)?.last?.myResponse == .declined)
        #expect(f.store.busy(f.key, from: wide.start, to: wide.end)?.count == 1, "a declined event blocks no time")
        #expect(f.store.record(f.key, id: "standup_20261014") != nil, "the rest of the series is untouched")
    }

    @Test func aDaylightSavingDayIsCoveredAndDrawnInTheUsersZone() async throws {
        let f = InstantFixture(events: [event("night", at(11, 1, 0, 30), at(11, 1, 3)), event("after", at(11, 1, 10), at(11, 1, 11)),
                                        event("next", at(11, 2, 9), at(11, 2, 10))])
        let model = f.sidebar()
        await model.show(day: at(11, 1))
        #expect(model.days.first?.events.map(\.id) == ["night", "after"])
        #expect(at(11, 2).timeIntervalSince(at(11, 1)) == 25 * 3_600)
        _ = model.moveDayInstantly(by: 1)
        #expect(model.days.first?.start == at(11, 2) && model.days.first?.events.map(\.id) == ["next"])
        #expect(f.calendar.readCalls == 1)
    }
}

@MainActor
@Suite struct CalendarInstantCacheTests {
    @Test func theSavedWeekShowsAtLaunchEvenOfflineAndOldSpansAreDropped() async throws {
        let key = CalendarCacheKey(provider: robin)
        let saved = CalendarEventRecord(event: event("saved", at(10, 10, 14), at(10, 10, 15)), etag: "v7")
        let old = CalendarEventRecord(event: event("old", at(9, 1, 14), at(9, 1, 15)), etag: "v1")
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [saved, old], ranges: [
            CalendarCoveredRange(start: at(9, 26), end: at(11, 24), fetchedAt: at(10, 10, 8)),
            CalendarCoveredRange(start: at(8, 20), end: at(9, 20), fetchedAt: at(10, 1, 8)),
        ], syncToken: "fake-0")])
        let f = InstantFixture(info: robin, cache: cache)
        f.calendar.failure = "Couldn't reach Google Calendar. Check the connection."
        let model = f.sidebar()
        await model.show(thread: nil)
        #expect(model.days.first?.events.map(\.id) == ["saved"] && model.state == .loaded)
        #expect(model.refreshNote == CalendarEventStore.couldNotRefresh, "a calm note; the saved events stay")
        #expect(model.days.first?.note == nil)
        #expect(f.calendar.readCalls == 1, "one refresh tried")
        #expect(f.store.record(key, id: "old") == nil, "a span read nine days ago is dropped at launch")
        _ = model.moveDayInstantly(by: 1)
        #expect(model.days.first?.start == at(10, 11) && model.state == .loaded, "the next day at once, offline")
        await f.store.flush()
        #expect(await cache.stored.first?.records.map(\.event.id) == ["saved"])
        #expect(await cache.stored.first?.ranges.count == 1)
    }

    @Test func aDisconnectedCalendarIsForgottenInMemoryAndOnDisk() async throws {
        let cache = InMemoryCalendarCache()
        let connection = FakeCalendarConnection(account: "robin@example.com", connected: true)
        let f = InstantFixture(events: [event("a", at(10, 10, 14), at(10, 10, 15))], info: robin, cache: cache,
                               connection: connection)
        f.env.startCalendarCache()
        let model = f.sidebar()
        await model.show(thread: nil)
        #expect(model.days.first?.events.map(\.id) == ["a"])
        await f.store.flush()
        #expect(await cache.stored.map(\.key) == [f.key])
        try await connection.disconnect()
        await eventually { f.store.keys.isEmpty }
        await f.store.flush()
        #expect(await cache.stored.isEmpty, "nothing of a disconnected calendar stays on this Mac")
        #expect(model.days.first?.events.isEmpty == true)
    }

    @Test func allDayEventsKeepTheirDatesInAnotherZoneAndOnlyBusyEventsBlockTime() async throws {
        let key = CalendarCacheKey(provider: robin)
        let offsite = CalendarEventRecord(event: CalendarEvent(id: "offsite", title: "Offsite", start: at(10, 14),
                                                               end: at(10, 15), isAllDay: true), readIn: newYork)
        let focus = CalendarEventRecord(event: event("focus", at(10, 14, 9), at(10, 14, 10)), isBusy: false)
        let meeting = CalendarEventRecord(event: event("meeting", at(10, 14, 11), at(10, 14, 12)))
        #expect(offsite.allDayDates == CalendarAllDayDates(start: "2026-10-14", end: "2026-10-15"))
        let cache = InMemoryCalendarCache(entries: [CalendarCacheEntry(key: key, records: [offsite, focus, meeting], ranges: [
            CalendarCoveredRange(start: at(9, 26), end: at(11, 24), fetchedAt: at(10, 10, 8))])])
        let store = CalendarEventStore(persistence: cache, timeZone: tokyo)
        await store.restore(now: at(10, 10, 9))
        let found = try #require(store.events(key, from: at(10, 14, 0, 0, tokyo), to: at(10, 15, 0, 0, tokyo)))
        let allDay = try #require(found.first { $0.id == "offsite" })
        #expect(allDay.isAllDay && allDay.start == at(10, 14, 0, 0, tokyo) && allDay.end == at(10, 15, 0, 0, tokyo),
                "the same dates, drawn on Tokyo's midnights")
        store.timeZone = newYork
        #expect(store.busy(key, from: at(10, 14), to: at(10, 15)) == [CalendarBusyInterval(start: at(10, 14, 11),
                                                                                          end: at(10, 14, 12))],
                "a transparent event and an all-day event do not block time")
        #expect(store.events(key, from: at(12, 1), to: at(12, 2)) == nil, "not covered: nil, never an empty day")
    }

    @Test func failuresBackOffAndOfflinePausesBackgroundRefreshes() async throws {
        let inner = FakeCalendar(events: [event("a", at(10, 14, 9), at(10, 14, 10))])
        let store = CalendarEventStore(timeZone: newYork)
        let key = CalendarEventStore.key(for: inner)
        let calendar = CalendarDateMentions.calendar(newYork)
        let visible = DateInterval(start: at(10, 14), end: at(10, 15))
        let now = at(10, 10, 9)
        func refresh(_ seconds: TimeInterval, force: Bool = false) async {
            await store.revalidate(key, provider: inner, visible: visible, today: now, calendar: calendar,
                                   now: now.addingTimeInterval(seconds), force: force)
        }
        inner.failure = "The calendar is offline."
        await store.ensure(key, provider: inner, from: visible.start, to: visible.end, today: now, calendar: calendar, now: now)
        #expect(inner.readCalls == 1 && store.lastError(key) == "The calendar is offline.")
        await refresh(5)
        #expect(inner.readCalls == 1, "waits 15 s after the first failure")
        await refresh(16)
        #expect(inner.readCalls == 2)
        await refresh(16 + 20)
        #expect(inner.readCalls == 2, "then 30 s")
        inner.failure = nil
        store.isOffline = { true }
        await refresh(3_600)
        #expect(inner.readCalls == 2, "offline: background refreshes pause")
        await refresh(3_600, force: true)
        #expect(inner.readCalls == 3 && store.lastError(key) == nil && store.events(key, from: visible.start, to: visible.end) != nil)
        store.isLowPower = { false }
        #expect(store.refreshInterval == 60)
        store.isLowPower = { true }
        #expect(store.refreshInterval == 300, "Low Power Mode: every five minutes")
    }

    @Test func nearAnEdgeTheNextOrPreviousMonthIsReadAtLowPriority() async throws {
        let inner = FakeCalendar()
        let store = CalendarEventStore(timeZone: newYork)
        let key = CalendarEventStore.key(for: inner)
        let calendar = CalendarDateMentions.calendar(newYork)
        let now = at(10, 10, 9)
        await store.ensure(key, provider: inner, from: at(10, 14), to: at(10, 15), today: now, calendar: calendar, now: now)
        #expect(inner.calls == [.window(from: at(9, 26), to: at(11, 24))])
        #expect(store.prefetchAdjacent(key, provider: inner, around: at(10, 20), calendar: calendar, now: now) == nil)
        await store.prefetchAdjacent(key, provider: inner, around: at(11, 20), calendar: calendar, now: now)?.value
        #expect(inner.calls.last == .window(from: at(11, 24), to: at(12, 24)), "the next month")
        await store.prefetchAdjacent(key, provider: inner, around: at(9, 28), calendar: calendar, now: now)?.value
        #expect(inner.calls.last == .window(from: at(8, 27), to: at(9, 26)), "the previous month")
        #expect(store.covers(key, from: at(8, 27), to: at(12, 24)) && inner.readCalls == 3)
    }

    @Test func aProviderWithoutTokensIsReadByWindowsAndTheDefaultChangeReadIsUnsupported() async throws {
        let inner = FakeCalendar(events: [event("a", at(10, 14, 9), at(10, 14, 10))])
        inner.supportsChangeTokens = false
        let store = CalendarEventStore(timeZone: newYork)
        let key = CalendarEventStore.key(for: inner)
        let calendar = CalendarDateMentions.calendar(newYork)
        let now = at(10, 10, 9)
        await store.ensure(key, provider: inner, from: at(10, 14), to: at(10, 15), today: now, calendar: calendar, now: now)
        #expect(store.syncToken(key) == nil)
        await store.revalidate(key, provider: inner, visible: DateInterval(start: at(10, 14), end: at(10, 15)), today: now,
                               calendar: calendar, now: now, force: true)
        #expect(inner.windowCalls == 2 && inner.changeCalls == 0)
        await #expect(throws: CalendarSyncError.unsupported) {
            _ = try await PlainCalendar().eventDelta(since: "anything")
        }
    }
}

private struct PlainCalendar: CalendarProviding {
    var info: CalendarProviderInfo { CalendarProviderInfo(name: "Plain") }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
    func freeBusy(from: Date, to: Date) async throws -> CalendarFreeBusy { CalendarFreeBusy(busy: []) }
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        throw CalendarError.refused("no")
    }
}
