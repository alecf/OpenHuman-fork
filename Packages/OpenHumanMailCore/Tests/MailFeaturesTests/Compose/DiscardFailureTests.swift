import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DiscardFailureTests {
    func savedDraft(_ f: ComposeFixture) async throws -> (ComposeSession, DraftKey) {
        await untilObserved { f.router.active != nil && f.router.list?.state == .loaded }
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Throwaway"
        session.updateBody(doc("Not needed after all"))
        await session.settle()
        let key = try #require(session.draftKey)
        return (session, key)
    }

    @Test func aDiscardThatFailsBringsTheDraftBackWithANotice() async throws {
        let f = ComposeFixture()
        let (session, key) = try await savedDraft(f)
        f.recorder.failDiscards(with: .unavailable("injected failure"))

        #expect(await f.run(.discardDraft, in: session))
        #expect(f.compose.windowSession == nil, "closed at once")
        f.discardGate.release()
        await f.compose.settle()

        #expect(f.recorder.calls.contains("discardDraft"))
        #expect(f.compose.windowSession === session, "the composer comes back")
        #expect(session.notice?.kind == .error)
        #expect(session.notice?.text.hasPrefix("Couldn't discard the draft.") == true)
        #expect(session.plainText == "Not needed after all" && session.subject == "Throwaway")
        #expect(await f.draftRow(key) != nil, "the draft is kept")
    }

    @Test func aDraftDeletedElsewhereMeanwhileStaysClosed() async throws {
        let f = ComposeFixture()
        let (session, _) = try await savedDraft(f)
        f.recorder.failDiscards(with: .notFound("draft"))

        #expect(await f.run(.discardDraft, in: session))
        f.discardGate.release()
        await f.compose.settle()

        #expect(f.compose.windowSession == nil && session.notice == nil)
    }

    @Test func aReviewDiscardThatFailsPutsTheDraftBackInTheQueue() async throws {
        let f = ComposeFixture()
        let gate = TestGate()
        f.env.review.timing = ComposeTiming(now: { fixedNow }, sleep: { _ in await gate.wait() })
        await untilObserved { f.router.active != nil && f.router.list?.state == .loaded }
        #expect(await f.run(.goReview))
        let review = f.env.review
        await untilObserved { review.isOpen && !review.rows.isEmpty }
        let first = try #require(review.current?.draft?.id)
        f.recorder.failDiscards(with: .unavailable("injected failure"))

        #expect(await f.run(.reviewDiscard))
        #expect(!review.rows.contains { $0.id == first.rawValue } && review.counts.discarded == 1)
        gate.release()
        await review.settle()

        #expect(f.recorder.calls.contains("discardDraft"))
        #expect(review.counts.discarded == 0)
        #expect(f.postedToasts.contains { $0.hasPrefix("Couldn't discard the draft.") })
        #expect(try #require(await f.draftRow(first)).review == .pending, "still waiting for review")
        await untilObserved { review.rows.contains { $0.id == first.rawValue } }
    }
}
