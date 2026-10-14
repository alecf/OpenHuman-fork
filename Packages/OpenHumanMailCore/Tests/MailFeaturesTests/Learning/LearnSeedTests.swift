import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct LearnSeedTests {
    typealias F = AutoLabelFixture

    private func row(_ n: Int64, unread: Bool, starred: Bool = false, from: String = "deals@shop.example",
                     daysAgo: Double = 1) -> ThreadRow {
        let at = fixedNow.addingTimeInterval(-daysAgo * 86_400)
        return ThreadRow(id: ThreadKey(account: AccountID(1), rowID: n, gmailThreadID: GmailThreadID("t\(n)")),
                         subject: "s", snippet: "", participantsDisplay: "x",
                         participants: [Participant(name: nil, email: "me@work.example", isMe: true, hasUnread: false),
                                        Participant(name: nil, email: from, isMe: false, hasUnread: unread)],
                         messageCount: 1, unreadCount: unread ? 1 : 0, draftCount: 0, attachmentCount: 0, isUnread: unread,
                         isStarred: starred, isImportant: false, userLabelIDs: [], lastMessageAt: at, sortAt: at)
    }

    @Test func signalsFollowTheConversationsState() {
        #expect(LearnSeed.signals(for: row(1, unread: true), inInbox: false) == [.archivedUnread])
        #expect(LearnSeed.signals(for: row(2, unread: false), inInbox: false) == [.archivedRead])
        #expect(LearnSeed.signals(for: row(3, unread: false, starred: true), inInbox: true) == [.starred])
        #expect(LearnSeed.signals(for: row(4, unread: true), inInbox: true).isEmpty, "still in the inbox: nothing yet")
    }

    @Test func observationsAreOldestFirstAndCarrySenderAndCategory() {
        typealias Item = SuperhumanLabelImportModel.ScanItem
        let items = [Item(row: row(1, unread: true, daysAgo: 1), category: "Marketing", superhumanName: "Marketing"),
                     Item(row: row(2, unread: false, daysAgo: 9), category: "Marketing", superhumanName: "Marketing"),
                     Item(row: row(3, unread: true, daysAgo: 3), category: "Respond", superhumanName: "Respond")]
        let result = LearnSeed.observations(items, inbox: [items[2].row.id])
        #expect(result.conversations == 2, "the one still in the inbox is skipped")
        #expect(result.observations.map(\.signal) == [.archivedRead, .archivedUnread])
        #expect(result.observations.map(\.date) == result.observations.map(\.date).sorted())
        #expect(result.observations.allSatisfy { $0.sender == "deals@shop.example" && $0.category == "Marketing" })
    }

    private func ready(_ f: F, learn: Bool = true, seed: Bool = true) async throws -> LearnedBehaviourCenter {
        let center = f.env.learning
        await center.start()
        if learn { await center.setOn(true) }
        if seed { await center.setSeedOn(true) }
        return center
    }

    @Test func offByDefaultAndNothingIsReadOrWritten() async throws {
        let f = F(writes: true)
        _ = try await F_seed(f)
        let center = try await ready(f, learn: false, seed: false)
        #expect(!center.seedOn)
        guard case .off = await center.seedFromSuperhumanLabels(account: F.work) else { throw TestFailure("ran while off") }
        let learnOnly = try await ready(f, learn: true, seed: false)
        guard case .off = await learnOnly.seedFromSuperhumanLabels(account: F.work) else { throw TestFailure("ran without opt-in") }
        #expect(center.behaviour.isEmpty && f.recorder.calls.isEmpty)
    }

    @Test func seedingCountsArchivedAndStarredOncePerAccountAndWritesNothingToGmail() async throws {
        let f = F(writes: true)
        let seeded = try await F_seed(f)
        let archived = Array(seeded.marketing.prefix(5))
        _ = try await f.store.apply(.markDone(archived))
        _ = try await f.store.apply(.star([seeded.meeting[0]]))
        let center = try await ready(f)
        let calls = f.recorder.calls.count
        let result = await center.seedFromSuperhumanLabels(account: F.work)
        guard case .seeded(let n) = result else { throw TestFailure("not seeded: \(result)") }
        #expect(n >= 6, "five archived and one starred, at least")
        let marketing = LearnedSubject(account: F.work, kind: .category, value: "Marketing")
        let tendency = try #require(center.behaviour.tendency(for: marketing, at: fixedNow))
        #expect(tendency.count(\.isDismissal) + (tendency.counts[.archivedRead] ?? 0) == 5)
        let meeting = center.behaviour.tendency(for: LearnedSubject(account: F.work, kind: .category, value: "Meeting"),
                                                at: fixedNow)
        #expect((meeting?.counts[.starred] ?? 0) >= 1, "the corpus may star more of them")
        #expect(center.behaviour.seededAccounts == [F.work])
        #expect(f.recorder.calls.count == calls, "no Gmail write, no label op")
        #expect(center.observationCount > 0)
        let before = center.behaviour.observationCount
        #expect(await center.seedFromSuperhumanLabels(account: F.work) == .alreadyDone)
        #expect(center.behaviour.observationCount == before)
    }

    @Test func resetForgetsTheSeedSoItCanBeRunAgain() async throws {
        let f = F(writes: true)
        let seeded = try await F_seed(f)
        _ = try await f.store.apply(.markDone(Array(seeded.marketing.prefix(2))))
        let center = try await ready(f)
        _ = await center.seedFromSuperhumanLabels(account: F.work)
        #expect(!center.behaviour.seededAccounts.isEmpty)
        await center.reset()
        #expect(center.behaviour.seededAccounts.isEmpty && center.behaviour.isEmpty)
    }

    @Test func aFileWrittenBeforeTheSeedFieldStillLoads() throws {
        let old = #"{"tendencies":[],"notNow":[],"accepted":[]}"#
        let decoded = try JSONDecoder().decode(LearnedBehaviour.self, from: Data(old.utf8))
        #expect(decoded.isEmpty && decoded.seededAccounts.isEmpty)
        var seeded = LearnedBehaviour()
        seeded.seededAccounts = [AccountID(1)]
        let again = try JSONDecoder().decode(LearnedBehaviour.self, from: JSONEncoder().encode(seeded))
        #expect(again.seededAccounts == [AccountID(1)])
    }

    private func F_seed(_ f: F) async throws -> SuperhumanLabelMigrationTests.Seeded {
        try await SuperhumanLabelMigrationTests.seed(f.store)
    }
}
