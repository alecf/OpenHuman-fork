import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ReviewQueueTests {
    static let mutations: Set<String> = ["apply", "undo", "createDraft", "updateDraft", "flushDraft", "discardDraft",
                                         "setReviewState", "resolveDraftConflict", "send", "cancelSend", "sendNow",
                                         "scheduleSend", "cancelScheduledSend"]

    func pendingKeys(_ f: ComposeFixture) async -> [DraftKey] {
        do { for try await rows in f.store.reviewQueue(ComposeFixture.work) { return rows.map(\.id) } } catch {}
        return []
    }

    func pendingRows(_ f: ComposeFixture) async -> [DraftSummary] {
        do { for try await rows in f.store.reviewQueue(ComposeFixture.work) { return rows } } catch {}
        return []
    }

    func open(_ f: ComposeFixture) async -> ReviewQueueModel {
        await f.loaded()
        #expect(await f.run(.goReview))
        let review = f.env.review
        await soon { review.isOpen && !review.rows.isEmpty }
        return review
    }

    @Test func openingTheQueueReadsAndNeverWrites() async throws {
        let f = ComposeFixture()
        let expected = await pendingKeys(f)
        #expect(expected.count >= 3)
        let review = await open(f)
        #expect(review.source == .pending(ComposeFixture.work))
        #expect(Set(review.rows.map(\.id)) == Set(expected.map(\.rawValue)))
        #expect(review.rows.allSatisfy(\.isActionable) && review.current?.draft?.agentNote != nil)
        #expect(f.router.actionContext().scope == .review)
        #expect(await f.run(.reviewNext) && review.cursor == 1)
        #expect(await f.run(.reviewPrevious) && review.cursor == 0)
        #expect(await f.run(.reviewSkip) && review.cursor == 1)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty, "\(f.recorder.calls)")
        #expect(f.store.pendingOperationCount == 0)
        #expect(await f.run(.goStarred))
        #expect(!review.isOpen)
    }

    @Test func skippingPastTheLastDraftFinishesTheQueue() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        for _ in 0..<review.rows.count { #expect(await f.run(.reviewSkip)) }
        #expect(review.isFinished)
        #expect(review.summary == "Sent 0 · Kept 0 · Discarded 0")
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
        #expect(await f.run(.reviewPrevious) && !review.isFinished)
    }

    @Test func keepApprovesTheDraftAndAdvancesWithoutSending() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        let first = try #require(review.current?.draft?.id)
        let count = review.rows.count
        #expect(await f.run(.reviewKeep))
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) } == ["setReviewState"])
        #expect(review.counts.kept == 1 && review.rows.count == count - 1)
        #expect(review.current?.draft?.id != first)
        let kept = try #require(await f.draftRow(first))
        #expect(kept.review == .approved && kept.canBeScheduled)
        #expect(!f.recorder.calls.contains("send"))
        await soon { f.env.review.rows.count == count - 1 }
    }

    @Test func discardIsDeferredAndUndoWithCmdZRestoresPending() async throws {
        let f = ComposeFixture()
        let gate = TestGate()
        f.env.review.timing = ComposeTiming(now: { fixedNow }, sleep: { _ in await gate.wait() })
        let review = await open(f)
        let first = try #require(review.current?.draft?.id)
        let count = review.rows.count
        #expect(await f.run(.reviewDiscard))
        await soon { f.env.undo?.canUndo == true }
        #expect(review.counts.discarded == 1 && review.rows.count == count - 1)
        #expect(try #require(await f.draftRow(first)).review == .rejected)
        #expect(!f.recorder.calls.contains("discardDraft"), "no discardDraft before the window ends")
        #expect(f.toasts.contains("Discarded draft"))

        #expect(await f.run(.undo))
        #expect(try #require(await f.draftRow(first)).review == .pending)
        await soon { review.rows.contains { $0.id == first.rawValue } }
        #expect(review.counts.discarded == 0)
        gate.release()
        await review.settle()
        #expect(!f.recorder.calls.contains("discardDraft"), "undone: nothing reached Gmail")

        let second = try #require(review.current?.draft?.id)
        #expect(await f.run(.reviewDiscard))
        await review.settle()
        #expect(f.recorder.calls.contains("discardDraft"))
        #expect(await f.draftRow(second) == nil)
    }

    @Test func closingTheQueueOrQuittingCompletesWaitingDiscards() async throws {
        let f = ComposeFixture()
        f.env.review.timing = ComposeTiming(now: { fixedNow }, sleep: { _ in await TestGate().wait() })
        let review = await open(f)
        let first = try #require(review.current?.draft?.id)
        #expect(await f.run(.reviewDiscard))
        await soon { f.env.undo?.canUndo == true }
        #expect(review.hasQuitWork && !f.recorder.calls.contains("discardDraft"))
        await review.prepareForQuit()
        #expect(f.recorder.calls.contains("discardDraft") && !review.hasQuitWork)
        #expect(await f.draftRow(first) == nil)
    }

    @Test func sendGoesThroughTheComposerOnlyWithItsUndoHold() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        let first = try #require(review.current?.draft?.id)
        #expect(await f.run(.reviewSend))
        await review.settle()
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1, "\(f.recorder.calls)")
        #expect(f.compose.heldSendCount == 1 && review.counts.sent == 1)
        #expect(review.rows.contains { $0.id == first.rawValue } == false || review.current?.draft?.id != first)
        await f.toast("Sending to ")
        #expect(await f.run(.undo))
        await soon { f.store.heldSendCount == 0 }
        #expect(f.recorder.calls.contains("cancelSend"))
    }

    @Test func sendIsRefusedInReadOnlyAndWritesNothing() async throws {
        let f = ComposeFixture(safeMode: .readOnly)
        let review = await open(f)
        for id in [ActionID.reviewSend, .reviewKeep, .reviewDiscard] {
            #expect(await f.run(id), "refused visibly, key consumed: \(id)")
        }
        #expect(f.toasts.contains("Read-only: Mail can't change your mail"))
        #expect(review.counts == .init() && f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
        #expect(f.compose.sessions.isEmpty)
        #expect(review.keep() == nil && review.discard() == nil)
    }

    @Test func editOpensTheRealComposerAndKeysActInsideIt() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        let first = try #require(review.current?.draft?.id)
        #expect(await f.run(.reviewEdit))
        await soon { f.compose.windowSession?.draftKey == first }
        #expect(f.router.actionContext().scope == .composer, "the composer has the keys while it is up")
        #expect(f.env.actions.availability(.reviewKeep, host: f.router) == .hidden)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
    }

    @Test func theDiffIsAgainstTheAgentSnapshotOnly() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        let draft = try #require(review.current?.draft)
        #expect(review.changes?.isEmpty == true, "an untouched agent draft has no changes")
        var edited = draft.fields
        edited.subject = "A new subject"
        edited.bodyText = (edited.bodyText ?? "") + " Extra words."
        edited.to.append(EmailAddress(email: "extra@elsewhere.example"))
        _ = try await f.recorder.updateDraft(draft.id, edited, expectedVersion: draft.version)
        await soon { review.changes?.isEmpty == false }
        let changes = try #require(review.changes)
        #expect(changes.changedFields == ["To", "Subject"])
        #expect(changes.body.contains { $0.op == .added && $0.text.contains("Extra words.") })
        #expect(!changes.body.contains { $0.op == .removed })
        let after = try #require(review.current?.draft)
        #expect(after.agentSnapshot == draft.agentSnapshot, "the baseline never moves with the user's edits")
        #expect(review.recipientFlags?.newRecipients.contains("extra@elsewhere.example") == true)
    }

    @Test func anAgentRevisionOnAnEditedDraftAsksWhichToKeep() async throws {
        let f = ComposeFixture()
        let review = await open(f)
        let draft = try #require(review.current?.draft)
        var mine = draft.fields
        mine.bodyText = "My own words."
        _ = try await f.recorder.updateDraft(draft.id, mine, expectedVersion: draft.version)
        var theirs = draft.fields
        theirs.bodyText = "A new agent version."
        f.store.agentUpdatesDraft(draft.id, fields: theirs, note: "Revised")
        await soon { review.current?.draft?.hasRemoteConflict == true }
        let conflict = try #require(review.conflictChanges)
        #expect(conflict.body.contains { $0.op == .removed && $0.text.contains("My") })
        #expect(conflict.body.contains { $0.op == .added && $0.text.contains("agent") })
        #expect(await f.draftRow(draft.id)?.fields.bodyText == "My own words.", "no silent overwrite of the user's edits")
        let before = f.recorder.calls.filter { $0 == "resolveDraftConflict" }.count
        await review.resolveConflict(.takeRemote)?.value
        #expect(f.recorder.calls.filter { $0 == "resolveDraftConflict" }.count == before + 1)
        await soon { review.current?.draft?.hasRemoteConflict == false }
        #expect(review.current?.draft?.fields.bodyText == "A new agent version.")
    }

    @Test func recipientFlagsMarkNewAndExternalAddresses() {
        let fields = DraftFields(to: [EmailAddress(email: "Dana@acme.example"), EmailAddress(email: "x@other.example")],
                                 cc: [EmailAddress(email: "colleague@example.com")])
        let work = ReviewRecipientFlags.compute(fields: fields, account: "robin@example.com", known: ["dana@acme.example"])
        #expect(work.newRecipients == ["x@other.example", "colleague@example.com"])
        #expect(work.externalRecipients == ["dana@acme.example", "x@other.example"])
        let personal = ReviewRecipientFlags.compute(fields: fields, account: "me@gmail.com", known: [])
        #expect(personal.externalRecipients.isEmpty && personal.newRecipients.count == 3)
    }

    @Test func aLinkQueueShowsExactlyTheNamedDraftsInOrderWithNotFoundRows() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let keys = await pendingKeys(f)
        let named = Array(keys.prefix(3))
        let refs = [DraftRef(account: AccountRef("Work"), draftID: named[2].rawValue),
                    DraftRef(account: AccountRef("robin@example.com"), draftID: named[0].rawValue),
                    DraftRef(account: AccountRef("Work"), draftID: "gone"),
                    DraftRef(account: AccountRef("nobody@example.org"), draftID: "x1"),
                    DraftRef(account: AccountRef("Work"), draftID: named[1].rawValue)]
        let outcome = f.router.route(.review(refs))
        #expect(outcome.handled)
        await soon { f.env.review.rows.map(\.state) == [.ready, .ready, .notFound, .accountNotSetUp, .ready] }
        let review = f.env.review
        #expect(review.rows.compactMap { $0.draft?.id } == [named[2], named[0], named[1]])
        #expect(f.router.activeAccountID == ComposeFixture.work)
        #expect(f.router.location == .reviewQueue(refs.map { DraftKey($0.draftID) }))
        #expect(await f.run(.reviewKeep))
        #expect(review.rows[0].outcome == .kept && review.cursor == 1)
        #expect(await f.run(.reviewSkip))
        #expect(review.cursor == 2 && !review.rows[2].isActionable)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) } == ["setReviewState"])
    }

    @Test func aLinkQueueFetchesAGmailDraftIDRead() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let rows = await pendingRows(f)
        let withGmailID = try #require(rows.first { $0.gmailDraftID != nil })
        let key = withGmailID.id
        let gmailID = try #require(withGmailID.gmailDraftID)
        _ = f.router.route(.review([DraftRef(account: AccountRef("Work"), draftID: gmailID.rawValue)]))
        await soon { f.env.review.rows.first?.state == .ready }
        #expect(f.env.review.rows.first?.draft?.id == key)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
    }

    @Test func withTheReviewModuleOffThereIsNoQueueEntryOrKey() async throws {
        let f = ComposeFixture(flags: FeatureFlags().with(.review, false))
        await f.loaded()
        #expect(!f.env.actions.contains(.reviewKeep) && !f.env.actions.contains(.goReview))
        #expect(!f.env.modules.locations.contains { $0.location == .reviewQueue(nil) })
    }
}

@Suite struct ReviewDiffTests {
    @Test func wordLevelRunsAreMergedInReadingOrder() {
        let runs = ReviewDiff.words(from: "Thanks for the note. Tuesday works", to: "Thanks for the note! Wednesday works fine.")
        #expect(runs == [.init(.same, "Thanks for the"), .init(.removed, "note. Tuesday"), .init(.added, "note! Wednesday"),
                         .init(.same, "works"), .init(.added, "fine.")])
        #expect(ReviewDiff.words(from: "same text", to: "same text") == [.init(.same, "same text")])
        #expect(ReviewDiff.words(from: "", to: "") == [])
    }

    @Test func hugeDraftsStayCheap() {
        let big = Array(repeating: "word", count: 5000).joined(separator: " ")
        let runs = ReviewDiff.words(from: big, to: big + " more")
        #expect(runs.map(\.op) == [.removed, .added])
    }

    @Test func htmlOnlyBodiesCompareAsText() {
        let a = DraftFields(subject: "S", bodyHTML: "<p>Hello <b>there</b></p>")
        var b = a
        b.bodyHTML = "<p>Hello <b>there</b> friend</p>"
        let changes = ReviewDiff.changes(from: a, to: b)
        #expect(changes.changedFields.isEmpty && changes.body.last == .init(.added, "friend"))
    }
}
