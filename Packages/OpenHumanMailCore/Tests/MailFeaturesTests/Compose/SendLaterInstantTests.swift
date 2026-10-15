import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SendLaterInstantTests {
    func readyDraft(_ f: ComposeFixture) async throws -> ComposeSession {
        await untilObserved { f.router.active != nil && f.router.list?.state == .loaded }
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Later"
        session.updateBody(doc("See you on Thursday"))
        await session.settle()
        return session
    }

    @Test func theComposerClosesBeforeTheScheduleIsWritten() async throws {
        let f = ComposeFixture()
        let session = try await readyDraft(f)
        let hold = Checkpoint()
        f.recorder.holdSchedules(at: hold)

        let scheduling = Task { await f.compose.schedule(session, at: fixedNow.addingTimeInterval(7_200)) }
        await hold.arrived()
        #expect(f.compose.windowSession == nil, "closed as soon as the time is picked")
        #expect(f.env.undo?.stack.isEmpty == true)

        hold.release()
        await scheduling.value
        let key = try #require(session.draftKey)
        #expect(await f.draftRow(key)?.status == .scheduled)
        #expect(f.compose.windowSession == nil)
        #expect(f.env.undo?.stack.last.map { String(localized: $0.title).hasPrefix("Scheduled for ") } == true)
    }

    @Test func aScheduleThatFailsBringsTheDraftBackWithANotice() async throws {
        let f = ComposeFixture()
        let session = try await readyDraft(f)
        let hold = Checkpoint()
        f.recorder.holdSchedules(at: hold)

        let scheduling = Task { await f.compose.schedule(session, at: fixedNow.addingTimeInterval(7_200)) }
        await hold.arrived()
        #expect(f.compose.windowSession == nil)
        f.store.failNextCommand(.unavailable("injected failure"))

        hold.release()
        await scheduling.value
        #expect(f.compose.windowSession === session, "the composer comes back")
        #expect(session.notice?.kind == .error)
        #expect(session.notice?.text.hasPrefix("Couldn't schedule.") == true)
        #expect(session.plainText.contains("See you on Thursday") && session.subject == "Later")
        #expect(session.to.tokens.map(\.email) == ["dana@acme.example"])
        let key = try #require(session.draftKey)
        let row = try #require(await f.draftRow(key), "the draft is kept")
        #expect(row.status != .scheduled)
        #expect(f.env.undo?.stack.isEmpty == true && f.compose.sending.isEmpty)
    }
}
