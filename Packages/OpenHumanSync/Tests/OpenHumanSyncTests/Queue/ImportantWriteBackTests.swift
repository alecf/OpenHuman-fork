import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ImportantWriteBackTests {
    static let important = GmailLabelID("IMPORTANT")

    struct Conversation {
        let thread: String
        let seed: String
        let reply: String
        let trashed: String
        let draft: String
        var visible: Set<String> { [seed, reply] }
    }

    struct Marks: Equatable {
        var seed: Bool
        var reply: Bool
        var trashed: Bool
        var draft: Bool
    }

    func conversation(_ h: WriteHarness, seedMarked: Bool, replyMarked: Bool, trashMarked: Bool) async throws -> Conversation {
        let thread = h.threads[0]
        let seed = try #require(await h.gmail.messageIDs(inThread: thread).first)
        if seedMarked { await h.gmail.modifyLabels(messageID: seed, add: ["IMPORTANT"]) }
        let reply = await h.gmail.deliver(subject: "Re: Seeded thread 0", body: "Synthetic reply.",
                                          labels: replyMarked ? ["INBOX", "IMPORTANT"] : ["INBOX"], threadID: thread)
        let trashed = await h.gmail.deliver(subject: "Re: Seeded thread 0", body: "Synthetic deleted reply.",
                                            labels: trashMarked ? ["TRASH", "IMPORTANT"] : ["TRASH"], threadID: thread)
        let raw = "From: me@example.com\r\nTo: alice@example.com\r\nSubject: Re: Seeded thread 0\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n\r\nSynthetic unsent reply.\r\n"
        let draft = try await h.gmail.createDraft(rawRFC822: Data(raw.utf8), threadID: thread)
        try await h.syncer.sync(reason: "poll")
        return Conversation(thread: thread, seed: seed, reply: reply.messageID, trashed: trashed.messageID,
                            draft: try #require(draft.message?.id))
    }

    func marks(_ h: WriteHarness, _ c: Conversation) async -> Marks {
        func marked(_ id: String) async -> Bool { await h.gmail.labelIDs(ofMessage: id)?.contains("IMPORTANT") == true }
        return Marks(seed: await marked(c.seed), reply: await marked(c.reply), trashed: await marked(c.trashed),
                     draft: await marked(c.draft))
    }

    func batchModifyBodies(_ h: WriteHarness) throws -> [[String: Any]] {
        try h.wire.requests.filter { $0.method == "POST" && $0.url.path().hasSuffix("/messages/batchModify") }.map {
            try #require(try JSONSerialization.jsonObject(with: $0.body ?? Data()) as? [String: Any])
        }
    }

    @Test func aMoveToImportantSendsOneBatchModifyForEveryVisibleMessageButNotTrashOrDrafts() async throws {
        let h = try await WriteHarness(threads: 1)
        let c = try await conversation(h, seedMarked: false, replyMarked: false, trashMarked: false)
        let ref = try h.ref(c.thread)
        #expect(try h.store.thread(ref)?.isImportant == false)

        let receipt = try h.store.apply(.modifyLabels([ref], add: [Self.important], remove: []), origin: .app)
        #expect(receipt.operationIDs.count == 1)
        #expect(try h.store.thread(ref)?.isImportant == true, "the row changes before Gmail answers")
        let report = await h.drainer(api: try h.client).drainOnce()
        #expect(report.succeeded == 1 && report.gmailCalls == 1)
        #expect(await h.gmail.callCount(.batchModify) == 1)

        let bodies = try batchModifyBodies(h)
        #expect(bodies.count == 1)
        #expect(Set(bodies.first?["ids"] as? [String] ?? []) == c.visible)
        #expect(bodies.first?["addLabelIds"] as? [String] == ["IMPORTANT"])
        #expect(await marks(h, c) == Marks(seed: true, reply: true, trashed: false, draft: false),
                "Trash is not visible and drafts can't carry labels")
        try await h.syncer.sync(reason: "poll")
        #expect(try h.store.thread(ref)?.isImportant == true)
    }

    @Test func aMoveToOtherRemovesTheMarkFromEveryVisibleMessage() async throws {
        let h = try await WriteHarness(threads: 1)
        let c = try await conversation(h, seedMarked: true, replyMarked: true, trashMarked: true)
        let ref = try h.ref(c.thread)
        #expect(try h.store.thread(ref)?.isImportant == true)

        _ = try h.store.apply(.modifyLabels([ref], add: [], remove: [Self.important]), origin: .app)
        #expect(try h.store.thread(ref)?.isImportant == false)
        #expect(await h.drainer(api: try h.client).drainOnce().succeeded == 1)
        let bodies = try batchModifyBodies(h)
        #expect(bodies.count == 1)
        #expect(Set(bodies.first?["ids"] as? [String] ?? []) == c.visible)
        #expect(bodies.first?["removeLabelIds"] as? [String] == ["IMPORTANT"])
        #expect(await marks(h, c) == Marks(seed: false, reply: false, trashed: true, draft: false), "Trash keeps its mark")
        try await h.syncer.sync(reason: "poll")
        #expect(try h.store.thread(ref)?.isImportant == false, "Gmail and Mail agree after the next sync")
    }

    @Test func undoAfterTheDrainPutsBackExactlyWhatChanged() async throws {
        let h = try await WriteHarness(threads: 1)
        let c = try await conversation(h, seedMarked: true, replyMarked: false, trashMarked: false)
        let ref = try h.ref(c.thread)
        let drainer = h.drainer(api: try h.client)
        let receipt = try h.store.apply(.modifyLabels([ref], add: [Self.important], remove: []), origin: .app)
        await drainer.drainOnce()
        #expect(await marks(h, c) == Marks(seed: true, reply: true, trashed: false, draft: false))

        let undo = try #require(try h.store.undo(receipt, origin: .app))
        #expect(undo.operationIDs.count == 1)
        await drainer.drainOnce()
        #expect(await h.gmail.callCount(.batchModify) == 2)
        #expect(await marks(h, c) == Marks(seed: true, reply: false, trashed: false, draft: false),
                "the message that already had the mark keeps it")
    }

    @Test func undoBeforeTheDrainerRunsSendsNothing() async throws {
        let h = try await WriteHarness(threads: 1)
        let c = try await conversation(h, seedMarked: true, replyMarked: true, trashMarked: false)
        let ref = try h.ref(c.thread)
        let receipt = try h.store.apply(.modifyLabels([ref], add: [], remove: [Self.important]), origin: .app)
        _ = try h.store.undo(receipt, origin: .app)
        #expect(try h.store.thread(ref)?.isImportant == true)
        let report = await h.drainer(api: try h.client).drainOnce()
        #expect(report.claimed == 0)
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(await marks(h, c) == Marks(seed: true, reply: true, trashed: false, draft: false))
    }
}
