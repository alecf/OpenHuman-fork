import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func key(_ n: Int64) -> ThreadKey { ThreadKey(account: AccountID(1), rowID: n, gmailThreadID: GmailThreadID("t\(n)")) }

private func row(_ n: Int64, unread: Bool = false, starred: Bool = false, labels: [Int64] = [],
                 subject: String? = nil) -> ThreadRow {
    let at = Date(timeIntervalSince1970: 1_791_000_000 - Double(n) * 60)
    return ThreadRow(id: key(n), subject: subject ?? "Subject \(n)", snippet: "s", participantsDisplay: "P\(n)",
                     participants: [], messageCount: 1, unreadCount: unread ? 1 : 0, draftCount: 0, attachmentCount: 0,
                     isUnread: unread, isStarred: starred, isImportant: false, userLabelIDs: labels, lastMessageAt: at,
                     sortAt: at)
}

@Suite struct OptimisticEffectTests {
    @Test func markDoneHidesOnlyWhereTheInboxDefinesTheList() {
        let command = MailCommand.markDone([key(1)])
        #expect(OptimisticEffect.of(command, in: .system(.inbox)).hidden == [key(1)])
        #expect(OptimisticEffect.of(command, in: .splitOther).hidden == [key(1)])
        #expect(OptimisticEffect.of(command, in: .split(SplitKey("s3"))).hidden == [key(1)])
        #expect(OptimisticEffect.of(command, in: .system(.starred)).isEmpty, "a done thread stays starred")
        #expect(OptimisticEffect.of(command, in: .system(.allMail)).isEmpty)
    }

    @Test func trashSpamAndTheirInverses() {
        #expect(OptimisticEffect.of(.trash([key(1)]), in: .system(.starred)).hidden == [key(1)])
        #expect(OptimisticEffect.of(.trash([key(1)]), in: .system(.trash)).isEmpty)
        #expect(OptimisticEffect.of(.untrash([key(1)]), in: .system(.trash)).hidden == [key(1)])
        #expect(OptimisticEffect.of(.markSpam([key(1)]), in: .system(.inbox)).hidden == [key(1)])
        #expect(OptimisticEffect.of(.markNotSpam([key(1)]), in: .system(.spam)).hidden == [key(1)])
        #expect(OptimisticEffect.of(.unsnooze([key(1)]), in: .system(.snoozed)).hidden == [key(1)])
        #expect(OptimisticEffect.of(.snooze([key(1)], until: .distantFuture), in: .system(.inbox)).hidden == [key(1)])
    }

    @Test func lookChangesArePatches() {
        #expect(OptimisticEffect.of(.markRead([key(1)]), in: .system(.inbox)).patches[key(1)] == RowPatch(isUnread: false))
        #expect(OptimisticEffect.of(.star([key(1), key(2)]), in: .system(.inbox)).patches.count == 2)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OptimisticEffect.of(.setReminder(key(1), dueAt: due, kind: .always), in: .system(.inbox))
            .patches[key(1)]?.reminderAt == .some(due))
        #expect(OptimisticEffect.of(.cancelReminder(key(1)), in: .system(.reminders)).hidden == [key(1)])
    }

    @Test func labelEditsHideOrPatch() {
        let rows = [GmailLabelID("Label_7"): Int64(7)]
        let move = MailCommand.modifyLabels([key(1)], add: [GmailLabelID("Label_7")], remove: [GmailLabelID("INBOX")])
        #expect(OptimisticEffect.of(move, in: .system(.inbox), labelRows: rows).hidden == [key(1)], "v (Move) leaves the inbox")
        let label = MailCommand.modifyLabels([key(1)], add: [GmailLabelID("Label_7")], remove: [])
        #expect(OptimisticEffect.of(label, in: .system(.inbox), labelRows: rows).patches[key(1)]?.addUserLabels == [7])
        let unlabel = MailCommand.modifyLabels([key(1)], add: [], remove: [GmailLabelID("Label_7")])
        #expect(OptimisticEffect.of(unlabel, in: .label(GmailLabelID("Label_7")), labelRows: rows).hidden == [key(1)])
    }
}

@Suite struct ThreadListOverlayTests {
    let start = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func hidesAndPatchesUntilTheStoreAgrees() throws {
        var overlay = ThreadListOverlay()
        let rows = [row(1), row(2, unread: true), row(3)]
        overlay.add(OptimisticEffect(hidden: [key(1)]), at: start)
        overlay.add(OptimisticEffect(patches: [key(2): RowPatch(isUnread: false)]), at: start)
        let (shown, hidden) = overlay.apply(to: rows)
        #expect(hidden == 1)
        #expect(shown.map(\.id) == [key(2), key(3)])
        #expect(shown[0].isUnread == false && shown[0].unreadCount == 0)

        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let none = overlay.confirm { before[$0] }
        #expect(none.isEmpty)
        let version = overlay.version
        let after = [key(2): row(2, unread: false), key(3): row(3)]
        let settled = overlay.confirm { after[$0] }
        #expect(settled.count == 2)
        #expect(overlay.isEmpty)
        #expect(overlay.version == version)
    }

    @Test func revertClearAndExpiry() throws {
        var overlay = ThreadListOverlay()
        let added = overlay.add(OptimisticEffect(hidden: [key(1)]), at: start)
        let ticket = try #require(added)
        let reverted = overlay.revert(ticket), again = overlay.revert(ticket)
        #expect(reverted)
        #expect(!again, "already gone")
        overlay.add(OptimisticEffect(hidden: [key(1), key(2)]), at: start)
        let cleared = overlay.clear(keys: [key(1)])
        #expect(cleared)
        #expect(overlay.hiddenKeys == [key(2)])
        #expect(overlay.earliestExpiry == start.addingTimeInterval(10))
        let early = overlay.expire(now: start.addingTimeInterval(9.9))
        let onTime = overlay.expire(now: start.addingTimeInterval(10))
        #expect(!early)
        #expect(onTime)
        #expect(overlay.isEmpty)
    }

    @Test func laterPatchesWinFieldByField() {
        var overlay = ThreadListOverlay()
        overlay.add(OptimisticEffect(patches: [key(1): RowPatch(isUnread: false, addUserLabels: [4])]), at: start)
        overlay.add(OptimisticEffect(patches: [key(1): RowPatch(isUnread: true, removeUserLabels: [4])]), at: start)
        let shown = overlay.apply(to: [row(1, labels: [4])]).rows[0]
        #expect(shown.isUnread)
        #expect(shown.userLabelIDs.isEmpty)
    }
}

@Suite struct ThreadListEditTests {
    func snapshot(_ ids: [Int64], placeholders: Int = 0, unread: Set<Int64> = []) -> ThreadListSnapshot {
        ThreadListSnapshot(rows: ids.map { row($0, unread: unread.contains($0)) }, placeholderCount: placeholders,
                           totalCount: ids.count + placeholders, hasMore: placeholders > 0)
    }

    func edit(_ change: ThreadListChange) -> ThreadListEdit? {
        if case .update(let edit) = change { return edit }
        return nil
    }

    @Test func newMailAtTheTopIsOneInsertion() throws {
        let e = try #require(edit(ThreadListEdit.between(snapshot([2, 3, 4]), snapshot([1, 2, 3, 4]))))
        #expect(e.inserted == IndexSet(integer: 0))
        #expect(e.removed.isEmpty && e.reconfigured.isEmpty)
    }

    @Test func aRowLeavingIsOneRemoval() throws {
        let e = try #require(edit(ThreadListEdit.between(snapshot([1, 2, 3, 4]), snapshot([1, 2, 4]))))
        #expect(e.removed == IndexSet(integer: 2))
        #expect(e.inserted.isEmpty)
    }

    @Test func aThreadBumpedToTheTopMoves() throws {
        let e = try #require(edit(ThreadListEdit.between(snapshot([1, 2, 3, 4]), snapshot([3, 1, 2, 4]))))
        #expect(e.removed == IndexSet(integer: 2))
        #expect(e.inserted == IndexSet(integer: 0))
        var keys: [Int64] = [1, 2, 3, 4]
        for i in e.removed.reversed() { keys.remove(at: i) }
        for i in e.inserted { keys.insert(3, at: i) }
        #expect(keys == [3, 1, 2, 4])
    }

    @Test func contentChangesAreReconfiguredInPlace() throws {
        let e = try #require(edit(ThreadListEdit.between(snapshot([1, 2, 3]), snapshot([1, 2, 3], unread: [2]))))
        #expect(e.reconfigured == IndexSet(integer: 1))
        #expect(e.removed.isEmpty && e.inserted.isEmpty)
    }

    @Test func pagesFillPlaceholdersWithoutChangingTheRowCount() throws {
        let old = snapshot([1, 2], placeholders: 5), new = snapshot([1, 2, 3, 4], placeholders: 3)
        let e = try #require(edit(ThreadListEdit.between(old, new)))
        #expect(e.reconfigured == IndexSet(integersIn: 2..<4))
        #expect(e.removed.isEmpty && e.inserted.isEmpty)
        #expect(old.displayCount == new.displayCount)
    }

    @Test func placeholderCountFollowsTheTotal() throws {
        let grow = try #require(edit(ThreadListEdit.between(snapshot([1, 2], placeholders: 3), snapshot([0, 1, 2], placeholders: 4))))
        #expect(grow.inserted == IndexSet([0, 6]), "new row at the top, one more placeholder at the end")
        let shrink = try #require(edit(ThreadListEdit.between(snapshot([1, 2], placeholders: 3), snapshot([1, 2], placeholders: 1))))
        #expect(shrink.removed == IndexSet(integersIn: 3..<5))
    }

    @Test func largeChangesReload() {
        let old = snapshot(Array(1...400)), new = snapshot(Array(1001...1400))
        #expect(ThreadListEdit.between(old, new) == .reload)
    }
}
