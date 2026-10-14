import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func la(_ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    CalendarDateMentions.calendar(losAngeles).date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
}

private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, calendar: String? = nil) -> CalendarEvent {
    CalendarEvent(id: id, title: "Event \(id)", start: start, end: end, isAllDay: allDay, calendarName: calendar)
}

@MainActor
struct SchedulingUIFixture {
    let env: AppEnvironment
    let calendar: FakeCalendar
    let thread: ThreadKey

    init(events: [CalendarEvent] = [], safeMode: SafeModeInfo = .normal) {
        let corpus = FakeCorpus.make(threadCount: 4, now: fixedNow)
        calendar = FakeCalendar(events: events)
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate, safeMode: safeMode),
                                  featureFlags: FeatureFlags(), calendar: calendar)
        thread = corpus.threads[0].row.id
    }

    func sidebar(_ bodies: [String] = [], people: [EmailAddress] = []) -> CalendarSidebarModel {
        let model = env.calendarSidebar!
        model.timeZone = losAngeles
        model.now = { la(10, 12, 11) }
        let text = CalendarThreadText(subject: "Planning", texts: ["Planning"] + bodies, participants: people)
        model.loadText = { _ in text }
        return model
    }
}

@Suite struct CalendarDayTimelineTests {
    @Test func overlappingEventsSitSideBySideAndOthersTakeTheWholeWidth() {
        let events = [event("a", la(10, 13, 9), la(10, 13, 10)), event("b", la(10, 13, 9, 30), la(10, 13, 10, 30)),
                      event("c", la(10, 13, 10, 30), la(10, 13, 11))]
        let timeline = CalendarDayTimeline(day: la(10, 13), events: events, focus: nil, timeZone: losAngeles,
                                           now: la(10, 12, 11))
        let byID = Dictionary(uniqueKeysWithValues: timeline.blocks.map { ($0.event.id, $0) })
        #expect(byID["a"]?.column == 0 && byID["a"]?.columns == 2)
        #expect(byID["b"]?.column == 1 && byID["b"]?.columns == 2)
        #expect(byID["c"]?.column == 0 && byID["c"]?.columns == 1, "touching is not overlapping")
        #expect(abs((byID["a"]?.top ?? 0) - 1.0 / 11.0) < 0.0001)
        #expect(abs((byID["a"]?.height ?? 0) - 1.0 / 11.0) < 0.0001)
        #expect(timeline.focus == nil && timeline.now == nil, "no focus; not today")
    }

    @Test func eventsOutsideTheAxisAreClampedAndAllDayEventsAreBars() {
        let events = [event("early", la(10, 13, 7), la(10, 13, 8, 30)), event("late", la(10, 13, 18), la(10, 13, 21)),
                      event("night", la(10, 13, 21), la(10, 13, 22)),
                      event("offsite", la(10, 13), la(10, 14), allDay: true)]
        let timeline = CalendarDayTimeline(day: la(10, 13, 15), events: events, focus: nil, timeZone: losAngeles,
                                           now: la(10, 12, 11))
        #expect(timeline.day == la(10, 13))
        #expect(timeline.allDay.map(\.id) == ["offsite"])
        #expect(Set(timeline.blocks.map(\.event.id)) == ["early", "late"], "an event after 7 PM is not on the axis")
        let early = timeline.blocks.first { $0.event.id == "early" }
        #expect(early?.top == 0 && early?.startsBefore == true)
        let late = timeline.blocks.first { $0.event.id == "late" }
        #expect(late?.endsAfter == true)
        #expect(abs((late.map { $0.top + $0.height } ?? 0) - 1) < 0.0001)
        #expect(timeline.hourMarks.count == 12, "8 AM … 7 PM")
        #expect(timeline.zoneLabel == losAngeles.abbreviation(for: la(10, 13)))
    }

    @Test func theFocusedSlotMarksItsConflictsAndTheCurrentTimeShowsOnTodayOnly() {
        let events = [event("standup", la(10, 12, 9), la(10, 12, 9, 30)), event("review", la(10, 12, 14), la(10, 12, 15)),
                      event("lunch", la(10, 12, 12), la(10, 12, 13))]
        let slot = DateInterval(start: la(10, 12, 14, 30), duration: 30 * 60)
        let timeline = CalendarDayTimeline(day: la(10, 12), events: events, focus: slot, timeZone: losAngeles,
                                           now: la(10, 12, 11))
        #expect(timeline.conflicts.map(\.id) == ["review"])
        #expect(timeline.blocks.filter(\.isConflict).count == 1)
        #expect(abs((timeline.focus?.top ?? 0) - 6.5 / 11.0) < 0.0001)
        #expect(abs((timeline.now ?? 0) - 3.0 / 11.0) < 0.0001)
        let tomorrow = CalendarDayTimeline(day: la(10, 13), events: [], focus: slot, timeZone: losAngeles,
                                           now: la(10, 12, 11))
        #expect(tomorrow.now == nil && tomorrow.focus == nil, "a slot on another day is not drawn")
    }

    @Test func aCalendarKeepsItsColour() {
        let one = CalendarDayTimeline.colorIndex(forCalendar: "Work")
        #expect(one == CalendarDayTimeline.colorIndex(forCalendar: "work"))
        #expect((0..<CalendarDayTimeline.colorCount).contains(one))
        #expect(CalendarDayTimeline.colorIndex(forCalendar: nil) == 0)
        #expect(CalendarLoadProgress(done: 1, total: 3).text == "Updating: 1 of 3")
    }
}

@MainActor
@Suite struct CalendarDayViewModelTests {
    @Test func theDayViewFollowsTheConversationsFirstUpcomingTime() async throws {
        let f = SchedulingUIFixture(events: [event("sync", la(10, 14, 15), la(10, 14, 16))])
        let model = f.sidebar(["Could we meet on October 14, 2026 at 3:30pm? Otherwise October 15, 2026 works."])
        await model.show(thread: f.thread)
        #expect(model.state == .loaded)
        #expect(model.progress == nil, "the status line goes once the days are read")
        let focus = try #require(model.focusSlot)
        #expect(focus.start == la(10, 14, 15, 30))
        let day = try #require(model.dayViewDay)
        #expect(day.start == la(10, 14))
        let timeline = model.timeline(for: day)
        #expect(timeline.conflicts.map(\.id) == ["sync"])
        #expect(model.dayHeader(day) == la(10, 14).formatted(Date.FormatStyle(timeZone: losAngeles).weekday(.abbreviated)
            .month(.abbreviated).day()))
    }

    @Test func aDraftBeingTypedMovesTheFocusAndADraftedEventWins() async throws {
        let f = SchedulingUIFixture()
        let model = f.sidebar(["No dates here."])
        await model.show(thread: f.thread)
        #expect(model.focusSlot == nil)
        await model.follow(typed: "How about October 16, 2026 at 10am?")
        #expect(model.focusSlot?.start == la(10, 16, 10))
        #expect(model.dayViewDay?.start == la(10, 16))
        await model.beginDraft(for: f.thread)
        model.draft?.start = la(10, 16, 13)
        model.draft?.end = la(10, 16, 14)
        #expect(model.focusSlot == DateInterval(start: la(10, 16, 13), end: la(10, 16, 14)))
    }

    @Test func anotherMentionedDayCanBeShownAlone() async throws {
        let f = SchedulingUIFixture()
        let model = f.sidebar(["October 14, 2026 or October 15, 2026?"])
        await model.show(thread: f.thread)
        #expect(model.days.map(\.start) == [la(10, 14), la(10, 15)])
        await model.show(day: la(10, 15, 9))
        #expect(model.days.map(\.start) == [la(10, 15)] && model.isBrowsing)
    }
}

@MainActor
@Suite struct PendingEventStoreTests {
    private func draft(_ title: String) -> CalendarEventDraft {
        CalendarEventDraft(title: title, start: la(10, 13, 10), end: la(10, 13, 10, 30), timeZone: losAngeles.identifier)
    }

    @Test func eventsAreKeptPerConversationOrDraftAndCancelAsksToGoBack() {
        let store = PendingEventStore()
        let session = UUID()
        let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t-1"))
        store.save(draft("Robin <> Dana"), for: .thread(thread), thread: thread, titleIsSuggested: true)
        store.save(draft("Intro call"), for: .draft(session), thread: nil)
        #expect(store.active == .draft(session))
        #expect(store.pending(for: .thread(thread))?.titleIsSuggested == true)
        store.save(draft("Robin and Dana"), for: .thread(thread), thread: thread)
        #expect(store.pending(for: .thread(thread))?.titleIsSuggested == false, "typed over: no longer the suggestion")
        store.deactivate(.thread(thread))
        #expect(store.active == nil && store.pending(for: .thread(thread)) != nil, "put away, not dropped")
        #expect(store.activate(.thread(thread)))
        store.cancel(.thread(thread))
        #expect(store.pending(for: .thread(thread)) == nil)
        #expect(store.returnRequest == PendingEventStore.ReturnRequest(id: 1, thread: thread))
        store.record(.up)
        store.record(.down)
        store.record(.up)
        #expect(store.feedbackCounts == [.up: 2, .down: 1])
    }

    @Test func theOldestGoPastTheCapacity() {
        let store = PendingEventStore()
        var clock = la(10, 12)
        store.now = { clock }
        for index in 0...PendingEventStore.capacity {
            clock = clock.addingTimeInterval(60)
            store.save(draft("Event \(index)"), for: .draft(UUID()), thread: nil)
        }
        #expect(store.events.count == PendingEventStore.capacity)
        #expect(!store.events.values.contains { $0.draft.title == "Event 0" })
    }
}

@MainActor
@Suite struct PendingEventSidebarTests {
    @Test func aDraftSurvivesShowingAnotherConversationAndCancelReturnsToTheEmail() async throws {
        let f = SchedulingUIFixture()
        let model = f.sidebar(["Lunch on October 14, 2026 at 12:30pm?"])
        let other = ThreadKey(account: f.thread.account, rowID: 9_999, gmailThreadID: GmailThreadID("other"))
        await model.show(thread: f.thread)
        await model.beginDraft(for: f.thread)
        model.draft?.title = "Edited title"
        #expect(f.env.pendingEvents.pending(for: .thread(f.thread))?.draft.title == "Edited title")
        await model.show(thread: other)
        #expect(model.draft == nil, "another conversation shows its own panel")
        #expect(f.env.pendingEvents.pending(for: .thread(f.thread)) != nil, "the event waits above the sidebar")
        await model.show(thread: f.thread)
        #expect(model.draft?.title == "Edited title", "back with its edits")
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.title == "Edited title", "b again brings the same pending event")
        model.cancelDraft()
        #expect(model.draft == nil && f.env.pendingEvents.events.isEmpty)
        #expect(f.env.pendingEvents.returnRequest?.thread == f.thread)
    }

    @Test func aHeldCreateIsNoLongerPending() async throws {
        let f = SchedulingUIFixture()
        let model = f.sidebar(["Call October 14, 2026 at 9am"],
                              people: [EmailAddress(name: "Dana Reyes", email: "dana@example.org")])
        model.createWindow = .seconds(60)
        await model.show(thread: f.thread)
        await model.beginDraft(for: f.thread)
        #expect(model.draft?.attendees.isEmpty == false)
        #expect(await model.createEvent(), "held behind its Undo")
        #expect(model.draft == nil && f.env.pendingEvents.pending(for: .thread(f.thread)) == nil)
        #expect(f.calendar.createCalls == 0, "nothing reached the calendar inside the window")
    }
}

@MainActor
@Suite struct ClickableDateTests {
    @Test func spansCarryTheirWordsAndPlace() throws {
        let text = "Thanks. Can we meet October 14, 2026 at 12:30pm? Or call me."
        let spans = CalendarDateMentions.spans(in: text, timeZone: losAngeles)
        let span = try #require(spans.first)
        #expect((text as NSString).substring(with: span.range) == span.words)
        #expect(span.words.contains("12:30"))
        #expect(span.mention.hasTime && span.mention.date == la(10, 14, 12, 30))
        #expect(CalendarDateMentions.span(at: span.range.location + 2, in: spans) == span)
        #expect(CalendarDateMentions.span(at: NSMaxRange(span.range), in: spans) == span, "the end counts (a caret)")
        #expect(CalendarDateMentions.span(at: 0, in: spans) == nil)
        #expect(CalendarDateMentions.spans(in: "No dates at all here.", timeZone: losAngeles).isEmpty)
    }

    @Test func thePeopleTitleIsYouThenThem() {
        let me = Account(id: AccountID(1), email: "robin.lee@example.org", displayName: "Robin Lee", alias: nil,
                         health: .active)
        let dana = EmailAddress(name: "Dana Reyes", email: "dana@example.org")
        let sam = EmailAddress(name: nil, email: "sam.ortiz@example.org")
        #expect(CalendarEventDraftBuilder.peopleTitle(me: me, others: [dana]) == "Robin <> Dana")
        #expect(CalendarEventDraftBuilder.peopleTitle(me: me, others: [dana, sam]) == "Robin <> Dana, Sam")
        #expect(CalendarEventDraftBuilder.peopleTitle(me: me, others: [dana, sam, dana, sam]) == "Robin <> Dana, Sam +2")
        #expect(CalendarEventDraftBuilder.peopleTitle(me: me, others: []) == nil)
    }

    @Test func aClickedDateOpensThePanelPrefilledAtThatTime() async throws {
        let f = SchedulingUIFixture()
        let dana = EmailAddress(name: "Dana Reyes", email: "dana@example.org")
        let model = f.sidebar(["Are you free on October 15, 2026 at 2pm?"], people: [dana])
        await model.show(thread: f.thread)
        let mention = CalendarDateMention(date: la(10, 15, 14), hasTime: true)
        await model.beginDraft(for: f.thread, at: mention)
        let draft = try #require(model.draft)
        #expect(draft.title.hasSuffix("<> Dana"))
        #expect(model.titleIsSuggested, "shown selected, ready to type over")
        #expect(draft.attendees.map(\.email) == ["dana@example.org"])
        #expect(draft.start == la(10, 15, 14) && draft.end == la(10, 15, 14, 30))
        #expect(draft.location.isEmpty && draft.notes.isEmpty)
        #expect(model.dayViewDay?.start == la(10, 15))
        #expect(f.calendar.createCalls == 0, "nothing is created before Save")
        model.draft?.location = "Room 4"
        await model.beginDraft(for: f.thread, at: CalendarDateMention(date: la(10, 16, 12), hasTime: false))
        #expect(model.draft?.start == la(10, 16, CalendarEventDraftBuilder.defaultHour))
        #expect(model.draft?.location == "Room 4")
    }

    @Test func aDateClickedInANewMessageGetsItsOwnPendingEvent() async throws {
        let f = SchedulingUIFixture()
        let model = f.sidebar()
        let session = UUID()
        await model.beginDraft(for: nil, at: CalendarDateMention(date: la(10, 20, 9), hasTime: true), key: .draft(session))
        #expect(model.draft?.start == la(10, 20, 9))
        #expect(model.draft?.attendees.isEmpty == true)
        #expect(f.env.pendingEvents.pending(for: .draft(session)) != nil)
        #expect(f.env.pendingEvents.active == .draft(session))
    }
}

@MainActor
@Suite struct DateTooltipKeyTests {
    @Test func theDayKeysAreTheComposersOnlyAndCollideWithNothing() throws {
        let ids: Set<ActionID> = [.calendarComposerPreviousDay, .calendarComposerNextDay]
        for id in ids {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == id })
            #expect(!descriptor.appearsInMenu, "no menu item: no key equivalent can collide (AppShellTests)")
        }
        let keys: Set<KeyBinding.Chord> = [KeyBinding.Chord(.character("_"), modifiers: .command),
                                           KeyBinding.Chord(.character("+"), modifiers: .command)]
        var owners: [KeyBinding.Chord: Set<ActionID>] = [:]
        for descriptor in ActionCatalog.all {
            for binding in descriptor.defaultBindings where binding.chords.count == 1 && keys.contains(binding.chords[0]) {
                let scopes = descriptor.scopes(of: binding)
                guard scopes.contains(.composer) || scopes.contains(.global) else { continue }
                owners[binding.chords[0], default: []].insert(descriptor.id)
            }
        }
        #expect(owners[KeyBinding.Chord(.character("_"), modifiers: .command)] == [.calendarComposerPreviousDay])
        #expect(owners[KeyBinding.Chord(.character("+"), modifiers: .command)] == [.calendarComposerNextDay])
        #expect(KeyBinding.Chord(.character("+"), modifiers: [.command, .shift])
                == KeyBinding.Chord(.character("+"), modifiers: .command))
    }

    @Test func withoutAComposerTheDayKeysAreNotOffered() {
        let f = SchedulingUIFixture()
        #expect(f.env.actions.contains(.calendarComposerNextDay))
        #expect(f.env.actions.availability(.calendarComposerNextDay, host: nil) == .hidden)
        #expect(f.env.actions.availability(.calendarComposerPreviousDay, host: nil) == .hidden)
    }
}
