import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct FailedOperationNoticesTests {
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))
    let other = ThreadKey(account: AccountID(1), rowID: 2, gmailThreadID: GmailThreadID("t2"))

    func info(_ kind: String, _ threads: [ThreadKey], id: Int64 = 1) -> FailedOperationInfo {
        FailedOperationInfo(id: id, account: AccountID(1), kind: kind, threads: threads, errorCode: "server_503",
                            failedAt: fixedNow)
    }

    func failures(_ store: FakeMailStore) async -> [FailedOperationInfo] {
        do {
            for try await list in store.failedOperations(nil) { return list }
        } catch {}
        return []
    }

    @Test func onlyTriageChangesCanBeRetriedAndTheWordsCarryNoContent() {
        #expect(FailedOperationNotices.command(for: info("markDone", [key])) == .markDone([key]))
        #expect(FailedOperationNotices.command(for: info("moveToInbox", [key])) == .moveToInbox([key]))
        #expect(FailedOperationNotices.command(for: info("trash", [key, other])) == .trash([key, other]))
        #expect(FailedOperationNotices.command(for: info("markSpam", [key])) == .markSpam([key]))
        #expect(FailedOperationNotices.command(for: info("star", [key])) == .star([key]))
        #expect(FailedOperationNotices.command(for: info("modifyLabels", [key])) == nil, "label ids are not kept")
        #expect(FailedOperationNotices.command(for: info("sendDraft", [])) == nil)
        #expect(FailedOperationNotices.command(for: info("markDone", [])) == nil, "nothing to run it on")
        #expect(FailedOperationNotices.message(for: info("markDone", [key])) == "Couldn't mark 1 conversation done")
        #expect(FailedOperationNotices.message(for: info("trash", [key, other])) == "Couldn't move 2 conversations to Trash")
        #expect(FailedOperationNotices.message(for: info("sendDraft", [])) == "Gmail didn't send a message. It's still in Drafts.")
        #expect(FailedOperationNotices.message(for: info("modifyLabels", [key, other])) == "Couldn't change labels on 2 conversations")
        #expect(FailedOperationNotices.message(for: info("createLabel", [])) == "Couldn't create a label in Gmail")
    }

    @Test func aFailureIsSaidOnceAndALabelEditOffersDismissOnly() {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
        let notices = FailedOperationNotices(environment: env)
        notices.present([info("modifyLabels", [key])])
        notices.present([info("modifyLabels", [key])])
        let said = env.notices.toasts.filter { $0.message == "Couldn't change labels on 1 conversation" }
        #expect(said.count == 1, "the same failure is said once")
        #expect(said.first?.style == .error && said.first?.expiresAt == nil, "an error that stays until answered")
        #expect(said.first?.actionTitle == "Dismiss" && said.first?.secondaryActionTitle == nil)
    }

    @Test func retryRunsTheCommandAgainAndClearsTheRefusedOne() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded()
        let target = try #require(f.router.list?.cursor)
        #expect(await f.run(.markDone))
        f.store.failRemote(code: "server_503")
        let refused = await failures(f.store)
        #expect(refused.map(\.kind) == ["markDone"] && refused.first?.threads == [target])

        let notices = FailedOperationNotices(environment: f.env)
        let follow = Task { await notices.run() }
        defer { follow.cancel() }
        let message = "Couldn't mark 1 conversation done"
        await eventually { f.env.notices.toasts.contains { $0.message == message } }
        let toast = try #require(f.env.notices.toasts.first { $0.message == message })
        #expect(toast.style == .error && toast.expiresAt == nil)
        #expect(toast.actionTitle == "Retry" && toast.secondaryActionTitle == "Dismiss")

        await f.env.notices.activate(toast.id)
        await eventuallyAsync { await failures(f.store).isEmpty }
        f.store.acknowledgeRemote()
        await eventually { f.rows.first { $0.id == target } == nil }
        #expect(!f.env.notices.toasts.contains { $0.message == message })
    }

    @Test func dismissRemovesItFromTheList() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded()
        #expect(await f.run(.toggleStar))
        f.store.failRemote(code: "server_503")
        #expect(await failures(f.store).count == 1)
        let notices = FailedOperationNotices(environment: f.env)
        let follow = Task { await notices.run() }
        defer { follow.cancel() }
        await eventually { f.env.notices.toasts.contains { $0.secondaryActionTitle == "Dismiss" } }
        let toast = try #require(f.env.notices.toasts.first { $0.secondaryActionTitle == "Dismiss" })
        await f.env.notices.activateSecondary(toast.id)
        await eventuallyAsync { await failures(f.store).isEmpty }
    }
}
