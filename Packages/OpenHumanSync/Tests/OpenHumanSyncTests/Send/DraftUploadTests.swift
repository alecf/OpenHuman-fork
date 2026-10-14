import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

@Suite struct DraftUploadTests {
    @Test func aNewDraftIsCreatedOnceThenUpdatedInPlace() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client)
        let id = try h.newDraft()
        var draft = try await h.upload(id, drainer: drainer)
        let gmailDraft = try #require(draft.gmailDraftID)
        let first = try #require(draft.gmailMessageID)
        #expect(!draft.isDirty && draft.localVersion == 1)
        _ = try h.store.updateDraft(id, content: MarkerAndScheduleTests.content("Edited"), expectedVersion: 1)
        draft = try await h.upload(id, drainer: drainer)
        #expect(draft.gmailDraftID == gmailDraft && draft.gmailMessageID != first)
        #expect(!draft.isDirty && draft.localVersion == 2)
        #expect(try await h.gmailDraftIDs() == [gmailDraft.rawValue])
        let methods = h.uploads().map(\.method)
        #expect(methods == ["POST", "PUT"])
        #expect(h.uploads()[1].raw.contains("Edited"))
        let ids = h.uploads().map { lines($0.raw, startingWith: "message-id:") }
        #expect(ids[0].count == 1 && ids[0] == ids[1] && ids[0][0].contains("oh.\(id.rawValue.lowercased())@"))
    }

    @Test func aReplyDraftIsUploadedIntoItsThread() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let thread = h.threads[1]
        let original = try #require(await h.gmail.messageIDs(inThread: thread).first)
        let id = try h.newDraft(subject: "Re: Seeded thread 1", mode: .reply, replyTo: GmailMessageID(original))
        let draft = try await h.upload(id, drainer: drainer)
        let message = try #require(draft.gmailMessageID).rawValue
        #expect(await h.gmail.messageIDs(inThread: thread).contains(message))
    }

    @Test func aDraftDeletedOnGmailIsCreatedAgainFromTheLocalCopy() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let before = try await h.upload(id, drainer: drainer)
        try await h.gmail.deleteDraft(id: try #require(before.gmailDraftID).rawValue)
        _ = try h.store.updateDraft(id, content: MarkerAndScheduleTests.content("Still mine"), expectedVersion: nil)
        let after = try await h.upload(id, drainer: drainer)
        #expect(after.gmailDraftID != before.gmailDraftID && !after.isDirty)
        #expect(try await h.gmailDraftIDs() == [try #require(after.gmailDraftID).rawValue])
    }

    @Test func anAmbiguousCreateIsAdoptedNotDuplicated() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let other = try h.newDraft(subject: "Another synthetic draft")
        try await h.upload(other, drainer: drainer)
        let id = try h.newDraft()
        let op = try h.store.saveDraftRemotely(id)
        await h.gmail.ambiguousFailureAfterCommit(.createDraft)
        #expect(await drainer.drainOnce().retried == 1)
        #expect(try await h.gmailDraftIDs().count == 2)
        h.instant.advance(by: OperationDrainer.backoff(attempts: 0))
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(try h.store.operation(op)?.status == .succeeded)
        #expect(await h.gmail.callCount(.createDraft) == 2)
        let drafts = try await h.gmailDraftIDs()
        #expect(drafts.count == 2)
        #expect(drafts.contains(try #require(try h.draft(id).gmailDraftID).rawValue))
        #expect(try h.draft(other).gmailDraftID != h.draft(id).gmailDraftID)
    }

    @Test func aDraftDiscardedAfterAnAmbiguousCreateLeavesNoOrphanOnGmail() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let id = try h.newDraft()
        let op = try h.store.saveDraftRemotely(id)
        await h.gmail.ambiguousFailureAfterCommit(.createDraft)
        await drainer.drainOnce()
        #expect(try await h.gmailDraftIDs().count == 1)
        #expect(try h.store.discardDraft(id) == nil)
        h.instant.advance(by: OperationDrainer.backoff(attempts: 0))
        await drainer.drainOnce()
        #expect(try h.store.operation(op)?.status == .cancelled)
        #expect(try await h.gmailDraftIDs().isEmpty)
        #expect(await h.gmail.callCount(.createDraft) == 1)
    }

    @Test func discardingDeletesTheGmailDraftAndAMissingOneCountsAsDeleted() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: h.gmail)
        let a = try h.newDraft(), b = try h.newDraft(subject: "Second synthetic draft")
        try await h.upload(a, drainer: drainer)
        let bDraft = try await h.upload(b, drainer: drainer)
        try await h.gmail.deleteDraft(id: try #require(bDraft.gmailDraftID).rawValue)
        let opA = try #require(try h.store.discardDraft(a))
        let opB = try #require(try h.store.discardDraft(b))
        #expect(await drainer.drainOnce().succeeded == 2)
        #expect(try h.store.operation(opA)?.status == .succeeded && h.store.operation(opB)?.status == .succeeded)
        #expect(try await h.gmailDraftIDs().isEmpty)
        let local = try h.newDraft()
        #expect(try h.store.discardDraft(local) == nil)
    }

    @Test func attachmentsComeFromTheDraftFolder() async throws {
        let h = try await WriteHarness(clock: sendClock(), onDisk: true)
        let drainer = h.drainer(api: try h.client)
        let pdf = Data("%PDF-1.4 synthetic attachment".utf8)
        let id = try h.newDraft()
        let folder = h.store.location.draftsDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pdf.write(to: folder.appendingPathComponent("a.pdf"))
        let attachment = DraftAttachment(localPath: "Drafts/\(id.rawValue)/a.pdf", filename: "synthetic.pdf",
                                         mimeType: "application/pdf", size: pdf.count, isInline: false)
        _ = try h.store.updateDraft(id, content: DraftContent(to: [EmailAddress(email: "bob@example.com")], cc: [], bcc: [],
                                                              subject: "With attachment", bodyHTML: "<p>See attached</p>",
                                                              attachments: [attachment]), expectedVersion: nil)
        try await h.upload(id, drainer: drainer)
        let raw = try #require(h.uploads().last).raw
        #expect(raw.contains("multipart/mixed") && raw.contains("synthetic.pdf"))
        #expect(raw.contains(pdf.base64EncodedString()))

        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.pdf"))
        _ = try h.store.updateDraft(id, content: DraftContent(to: [EmailAddress(email: "bob@example.com")], cc: [], bcc: [],
                                                              subject: "With attachment", bodyHTML: "<p>Edited</p>",
                                                              attachments: [attachment]), expectedVersion: nil)
        let op = try h.store.saveDraftRemotely(id)
        let events = EventLog()
        #expect(await h.drainer(api: try h.client, events: events).drainOnce().failed == 1)
        #expect(try h.store.operation(op)?.lastErrorCode == "attachment_missing")
        #expect(try h.draft(id).lastError == "attachment 1: local file missing")
        #expect(events.failedOperations.map(\.id) == [op])
        try? FileManager.default.removeItem(at: h.store.location.directory)
    }

    @Test func editsWithinFiveSecondsBecomeOneUploadAndFlushUploadsAtOnce() async throws {
        let clock = TestClock(now: Date())
        let h = try await WriteHarness(clock: clock)
        let enqueued = EventCounter()
        let debouncer = DraftSaveDebouncer(store: h.store, clock: clock) { _, _ in enqueued.bump() }
        let id = try h.newDraft()
        for n in 2...4 {
            _ = try h.store.updateDraft(id, content: MarkerAndScheduleTests.content("Typing \(n)"), expectedVersion: n - 1)
            await debouncer.noteEdit(id)
        }
        #expect(await debouncer.pending == [id])
        #expect(try uploads(h, id).isEmpty)
        clock.advance(by: .seconds(4))
        #expect(try uploads(h, id).isEmpty)
        clock.advance(by: .seconds(1))
        try await eventually("one upload queued") { try uploads(h, id).count == 1 }
        #expect(try uploads(h, id).first?.payload == .upsertDraft(draftID: id, version: 4))
        #expect(await debouncer.pending.isEmpty && enqueued.count == 1)

        _ = try h.store.updateDraft(id, content: MarkerAndScheduleTests.content("Typing 5"), expectedVersion: 4)
        await debouncer.noteEdit(id)
        let flushed = await debouncer.flush(id)
        #expect(flushed != nil && enqueued.count == 2)
        #expect(try uploads(h, id).count == 1 && uploads(h, id).first?.payload == .upsertDraft(draftID: id, version: 5))
        #expect(await debouncer.pending.isEmpty)
        clock.advance(by: .seconds(10))
        #expect(enqueued.count == 2)

        _ = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        #expect(await debouncer.flush(id) == nil)
    }

    private func uploads(_ h: WriteHarness, _ id: DraftID) throws -> [OperationItem] {
        try h.ops([.pending]).filter { if case .upsertDraft(id, _) = $0.payload { return true } else { return false } }
    }
}

final class EventCounter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
