import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

private func pacific(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarDateMentions.calendar(losAngeles)
        .date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func reply(_ label: String, _ body: String, id: Int) -> QuickReply {
    QuickReply(id: id, label: label, body: body, linkHostsAddedByAI: [])
}

@Suite struct ReplySuggestionsMergeTests {
    private let busy = ReplySuggestion(id: "calendar.busy", kind: .busy, label: "1:00 PM is busy — Design review",
                                       body: nil, help: "")
    private let counter = ReplySuggestion(id: "calendar.counter", kind: .scheduling(.askForOtherTimes),
                                          label: "Counter-propose Tuesday", body: "Could Tuesday work instead?", help: "")
    private let ask = ReplySuggestion(id: "calendar.ask", kind: .scheduling(.askForOtherTimes),
                                      label: "Ask for other times", body: "Could you send a few other times?", help: "")
    private let accept = ReplySuggestion(id: "calendar.accept", kind: .scheduling(.accept), label: "Accept 1:00 PM",
                                         body: "Tue, Oct 13, 1:00 – 1:30 PM PDT works for me. See you then.", help: "")
    private let ai = [reply("Sounds good", "Sounds good, thanks.", id: 0),
                      reply("Not this time", "Thanks, but I can't make it.", id: 1),
                      reply("Another time?", "Could we find another time?", id: 2),
                      reply("Ask for details", "Could you share a few more details first?", id: 3)]

    @Test func aBusyTimeKeepsTheCalendarFirstAndNoReplyThatSaysItWorks() {
        let set = ReplySuggestions.merge(scheduling: [busy, counter, ask], quickReplies: ai)
        #expect(set.map(\.id) == ["calendar.busy", "calendar.counter", "calendar.ask", "ai.1", "ai.3"])
        #expect(!set.contains { ReplySuggestions.acceptsTime($0.label + "\n" + ($0.body ?? "")) },
                "next to 'busy', nothing accepts the time")
        #expect(set.filter { $0.label == "Another time?" }.isEmpty, "the calendar already asks for other times")
    }

    @Test func aFreeTimesAcceptIsTheOnlyOneThatAccepts() {
        let set = ReplySuggestions.merge(scheduling: [accept, ask], quickReplies: ai)
        #expect(set.map(\.id) == ["calendar.accept", "calendar.ask", "ai.1", "ai.3"])
        #expect(set.filter { ReplySuggestions.acceptsTime($0.body ?? "") }.map(\.id) == ["calendar.accept"],
                "the calendar's Accept carries the exact time; the AI's 'Sounds good' would repeat it without one")
    }

    @Test func withoutAProposedTimeTheAIRepliesAreUnchanged() {
        let set = ReplySuggestions.merge(scheduling: [], quickReplies: Array(ai.prefix(3)))
        #expect(set.map(\.body) == ai.prefix(3).map(\.body) && set.allSatisfy { $0.kind == .quickReply })
        #expect(set.map(\.id) == ["ai.0", "ai.1", "ai.2"])
    }

    @Test func repeatsAndTheLimit() {
        let same = reply("ask for other times", "Could you send a few  other times?", id: 9)
        #expect(ReplySuggestions.merge(scheduling: [ask], quickReplies: [same]).count == 1, "same label and text")
        let many = (0..<9).map { reply("Reply \($0)", "Body \($0)", id: $0) }
        #expect(ReplySuggestions.merge(scheduling: [busy, counter], quickReplies: many).count == ReplySuggestions.limit)
    }

    @Test func acceptanceWordsAndTheirNegations() {
        for yes in ["Works for me", "Sounds good, see you then!", "That works.", "I’ll be there", "Count me in",
                    "Confirmed for Tuesday"] {
            #expect(ReplySuggestions.acceptsTime(yes), "\(yes)")
        }
        for no in ["That doesn't work for me", "Thanks, but I can't make it.", "Could you share more details?",
                   "Let me check my calendar"] {
            #expect(!ReplySuggestions.acceptsTime(no), "\(no)")
        }
        #expect(ReplySuggestions.asksForOtherTimes("Could we find another time?"))
        #expect(!ReplySuggestions.asksForOtherTimes("Sounds good"))
    }
}

@MainActor
private struct ProposalFixture {
    let f: AIFixture
    let assistant: SchedulingAssistant
    let calendar: FakeCalendar
    let row: InlineReplyRow

    static let meeting = CalendarEvent(id: "ev-review", title: "Design review", start: pacific(13, 13),
                                       end: pacific(13, 14), organizerIsMe: true)

    init(busy: Bool, settings: AISettings = AISettings(draftReplies: .onDeviceAuto)) async throws {
        calendar = FakeCalendar(events: busy ? [Self.meeting] : [])
        f = AIFixture(settings: settings, calendar: calendar)
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        assistant = try #require(f.env.scheduling)
        assistant.timeZone = losAngeles
        assistant.now = { pacific(12, 9) }
        assistant.language = nil
        assistant.loadMessage = { _ in
            SchedulingMessage(key: newest, subject: "Re: Sync up", senderName: "Dana Ruiz <dana@example.org>",
                              sentAt: pacific(12, 9), text: "Hi, no problem. How about 1pm tomorrow?", isFromMe: false)
        }
        await assistant.analyze(thread)
        row = f.center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        let row = self.row
        await eventually { row.aiState == .ready || row.aiState == .none }
        try #require(row.state == .ready)
    }

    var thread: ThreadKey { row.thread }
}

@MainActor
@Suite(.serialized) struct OneSuggestionSetTests {
    @Test func oneOrderedSetTheCalendarFirstAndABusyTimeNeverSaysItWorks() async throws {
        let p = try await ProposalFixture(busy: true)
        let items = p.row.items
        #expect(items.first?.kind == .busy && items.first?.isWarning == true && items.first?.body == nil)
        #expect(items.prefix(3).allSatisfy { $0.kind != .quickReply }, "the calendar's first")
        #expect(items.contains { $0.kind == .quickReply }, "then the AI's")
        for item in items {
            let words = item.label + "\n" + (item.body ?? "")
            #expect(!ReplySuggestions.acceptsTime(words) && !words.lowercased().contains("works for me"),
                    "busy: \(item.label)")
        }
        #expect(!items.contains { $0.schedulingOption == .accept })
        #expect(p.row.preview?.id == "calendar.counter", "the first reply is previewed, not the busy chip")
        #expect(p.row.replyCount == items.count - 1)
    }

    @Test func aFreeTimeOffersAcceptFirstAndNoAIReplyThatAcceptsToo() async throws {
        let p = try await ProposalFixture(busy: false)
        let items = p.row.items
        #expect(items.first?.schedulingOption == .accept && items.first?.body?.contains("works for me") == true)
        #expect(items.dropFirst().first?.kind == .createEvent)
        #expect(items.filter { ReplySuggestions.acceptsTime($0.body ?? "") }.count == 1)
    }

    @Test func everySuggestionGoesInAsOneUndoableEditAndAnotherReplacesItUntilTheUserTypes() async throws {
        let p = try await ProposalFixture(busy: true)
        let (session, editor) = try await p.f.reply(p.thread)
        let replies = p.row.items.filter(\.isReply)
        #expect(replies.count >= 3)
        for (offset, item) in replies.enumerated() {
            let used = try #require(await p.row.use(item))
            #expect(used === session)
            let body = try #require(item.body)
            #expect(editor.text == body && session.plainText == body, "exactly \(item.id)")
            #expect(editor.replacements.count == offset + 1, "one edit (one ⌘Z) for \(item.id)")
            #expect(editor.replacements.last?.range == 0..<((offset == 0 ? "" : replies[offset - 1].body ?? "") as NSString).length,
                    "over the empty body, then over the suggestion put in before (switching versions)")
            #expect(editor.caretPlacements.last == (body as NSString).length, "caret at the end")
            #expect(session.suggestionInBody == body)
            #expect(session.isAutoDraft == (item.kind == .quickReply), "Auto Draft for the AI's text, Draft for the app's")
            if let option = item.schedulingOption {
                #expect(session.scheduling?.option == option, "the calendar reply carries its times to the send")
            } else {
                #expect(session.scheduling == nil)
            }
        }
        editor.type(" Thanks!")
        #expect(session.suggestionInBody == nil && session.holdsUserText)
        let typed = editor.text
        let count = editor.replacements.count
        #expect(p.row.state == .none)
        #expect(await p.row.use(try #require(replies.first)) == nil)
        #expect(editor.text == typed && editor.replacements.count == count, "the user's text is kept, nothing added")
        #expect(!p.f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" }, "nothing is sent")
        #expect(p.calendar.createCalls == 0 && p.calendar.moveCalls == 0, "the calendar is not written")
    }

    @Test func aClickWithTheReplyOpenUsesAtOnceAndTheActionChipsDoTheirAction() async throws {
        let p = try await ProposalFixture(busy: true)
        let (session, editor) = try await p.f.reply(p.thread)
        let items = p.row.items
        let index = try #require(items.firstIndex { $0.kind == .quickReply })
        p.row.select(index)
        p.row.select(index)
        await eventually { !editor.text.isEmpty }
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.text == items[index].body && editor.replacements.count == 1)
        #expect(p.row.usedID == items[index].id && p.row.state == .ready, "the row stays above the reply")
        #expect(session.isAutoDraft)
        p.row.select(0)
        await eventually { p.assistant.conflictThread == p.thread }
        #expect(editor.replacements.count == 1)
    }

    @Test func theCalendarsOwnPathsTakeTheSamePathAndRespectTypedText() async throws {
        let p = try await ProposalFixture(busy: true)
        let (session, editor) = try await p.f.reply(p.thread)
        let analysis = try #require(p.assistant.analyses[p.thread])
        let used = try #require(await p.assistant.draft(.today(analysis.today), in: p.thread))
        #expect(used === session && editor.replacements.count == 1 && !editor.text.isEmpty)
        #expect(session.scheduling?.option == .today(analysis.today) && session.notice == nil)
        editor.type(" My words.")
        let typed = editor.text
        #expect(await p.assistant.draft(.askForOtherTimes, in: p.thread) == nil)
        #expect(editor.text == typed && session.notice?.text.contains("empty reply") == true)
        let moves = try #require(analysis.moves)
        let fresh = try await ProposalFixture(busy: true)
        let moved = try #require(await fresh.assistant.draft(.acceptAndMove(moves), in: fresh.thread))
        #expect(!moved.plainText.lowercased().contains("works for me"))
        #expect(moved.plainText.contains("I'll move things around"))
    }

    @Test func theComposersOwnStripUsesTheSameSetAndPath() async throws {
        let p = try await ProposalFixture(busy: true, settings: AISettings(draftReplies: .onDeviceAuto,
                                                                         instantReplyStrip: true))
        let (session, editor) = try await p.f.reply(p.thread)
        session.placement = .modal
        p.f.compose.attachInstantReply(session)
        let strip = try #require(session.instantReply)
        await eventually { strip.phase == .ready }
        #expect(strip.suggestions.map(\.id) == p.row.items.filter(\.isReply).map(\.id))
        #expect(strip.options.first?.label.hasPrefix("Counter-propose") == true)
        strip.use(0, via: .command)
        let counter = try #require(strip.suggestions.first?.body)
        #expect(editor.text == counter && editor.replacements.count == 1)
        #expect(session.scheduling?.option == p.row.items.first { $0.id == "calendar.counter" }?.schedulingOption)
    }
}
