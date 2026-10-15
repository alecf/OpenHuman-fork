import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(1))) struct InstantLabelAndSnoozeTests {
    static let name = "Synthetic Kestrel"

    func loadedList(_ f: ActionFixture) async throws -> ThreadListModel {
        await untilObserved { f.router.list?.state == .loaded && !f.rows.isEmpty }
        return try #require(f.router.list)
    }

    func labelChips(_ list: ThreadListModel, _ key: ThreadKey) -> [String] {
        guard let row = list.row(for: key) else { return [] }
        return list.chips(for: row).filter { $0.kind == .label }.map(\.title)
    }

    @Test func aNewLabelShowsOnTheConversationBeforeItIsWritten() async throws {
        let f = ActionFixture()
        let list = try await loadedList(f)
        let key = try #require(list.rows.first { $0.userLabelIDs.isEmpty }?.id)
        let handler = try #require(f.registry.threadActions)

        let task = handler.createLabel(named: Self.name, account: key.account, applyTo: [key], host: f.router)
        #expect(labelChips(list, key) == [Self.name], "shown in the same turn")
        #expect(!f.store.labelNames(of: key).contains(Self.name), "before the write")
        await task?.value
        #expect(f.store.labelNames(of: key).contains(Self.name))

        await untilObserved {
            guard let stored = f.router.active?.labels.first(where: { $0.name == Self.name }) else { return false }
            return list.labels[stored.id] != nil && list.rows.first { $0.id == key }?.userLabelIDs == [stored.id]
        }
        #expect(labelChips(list, key) == [Self.name], "handed over to the stored label without a second chip")
        #expect(list.labels.values.filter { $0.name == Self.name }.count == 1)
    }

    @Test func aNewLabelThatFailsComesOffTheConversationWithANotice() async throws {
        let f = ActionFixture()
        let list = try await loadedList(f)
        let key = try #require(list.rows.first { $0.userLabelIDs.isEmpty }?.id)
        let handler = try #require(f.registry.threadActions)
        f.store.failNextCommand(.unavailable("injected failure"))

        let task = handler.createLabel(named: Self.name, account: key.account, applyTo: [key], host: f.router)
        #expect(labelChips(list, key) == [Self.name])
        await task?.value

        #expect(labelChips(list, key).isEmpty, "taken off when the write fails")
        #expect(!list.labels.values.contains { $0.name == Self.name })
        #expect(list.optimisticKeys.isEmpty)
        #expect(f.toastMessages.contains("Couldn't create label \(Self.name)"))
        #expect(!f.store.labelNames(of: key).contains(Self.name))
    }

    @Test func snoozingOutsideTheInboxMarksTheConversationAtOnce() async throws {
        let f = ActionFixture(location: .system(.allMail))
        let list = try await loadedList(f)
        let key = try #require(list.rows.first { $0.snoozedUntil == nil }?.id)
        let handler = try #require(f.registry.threadActions)
        let wake = Date(timeIntervalSince1970: 4_000_000_030)

        let task = handler.snooze([key], until: wake, host: f.router)
        let row = try #require(list.row(for: key), "a snoozed conversation stays in All Mail")
        #expect(row.snoozedUntil == ScheduleStamp.floorToMinute(wake))
        #expect(ThreadRowFormatting.indicators(for: row, location: list.location, now: fixedNow).contains(.snoozed))
        await task?.value
    }
}
