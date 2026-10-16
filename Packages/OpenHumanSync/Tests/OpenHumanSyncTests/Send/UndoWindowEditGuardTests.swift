import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct UndoWindowEditGuardTests {
    @Test func anAgentEditIsRefusedDuringTheUndoWindowAndTheQueuedSendIsUnchanged() async throws {
        let h = try await WriteHarness(clock: sendClock())
        let drainer = h.drainer(api: try h.client)
        let id = try h.newDraft(origin: .cli, review: .pending, headers: MarkerAndScheduleTests.agentHeaders)
        let receipt = try h.store.send(id, undoWindow: .seconds(10), origin: .app)
        #expect(try h.draft(id).state == .sending)
        let queued = try h.ops([.pending])
        #expect(queued.contains { $0.kind == .sendDraft })
        let before = try h.draft(id)

        let hijacked = DraftContent(to: [EmailAddress(email: "mallory@example.com")], cc: [], bcc: [],
                                    subject: "Hijacked subject", bodyHTML: "<p>Hijacked body</p>", attachments: [])
        #expect(throws: StoreError.self) {
            _ = try h.store.updateAgentDraft(id, content: hijacked, agentNote: "late edit")
        }
        #expect(throws: StoreError.self) { _ = try h.store.saveDraftRemotely(id) }

        let after = try h.draft(id)
        #expect(after.state == .sending)
        #expect(after.content == before.content)
        #expect(after.localVersion == before.localVersion)
        #expect(try h.ops([.pending]).map(\.id) == queued.map(\.id))

        h.advancePast(receipt)
        await drainer.drainOnce()
        #expect(try h.draft(id).state == .sent)
        let deliveries = await h.gmail.deliveries()
        #expect(!deliveries.isEmpty)
        for delivery in deliveries {
            let raw = String(decoding: delivery.raw, as: UTF8.self)
            #expect(delivery.recipient == "bob@example.com")
            #expect(!raw.contains("Hijacked") && !raw.contains("mallory@example.com"))
            #expect(lines(raw, startingWith: "subject:") == ["Subject: Synthetic draft"])
        }
    }
}
