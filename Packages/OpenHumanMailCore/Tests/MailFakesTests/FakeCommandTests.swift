import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func markDoneRemovesTheRowWithinOneEmissionAndUndoRestoresIt() async throws {
    let store = makeStore()
    var inbox = store.threadWindow(.system(.inbox), account: work, limit: 50).makeAsyncIterator()
    let before = try #require(try await inbox.next())
    let target = before.rows[0].id
    let token = try await store.apply(.markDone([target]))
    let after = try #require(try await inbox.next())
    #expect(!after.rows.contains { $0.id == target })
    #expect(after.totalCount == before.totalCount - 1)
    #expect(store.pendingOperationCount == 1)
    #expect(try await window(store, .system(.allMail)).rows.first { $0.id == target }?.hasPendingChanges == true)

    let redo = try #require(try await store.undo(token))
    let restored = try #require(try await inbox.next())
    #expect(restored.rows.first?.id == target)
    #expect(restored.totalCount == before.totalCount)
    #expect(store.pendingOperationCount == 0)
    let message = try #require(special(0).detail.messages.last?.id)
    #expect(store.serverLabels(of: message).contains(GmailLabelID("INBOX")))

    _ = try await store.undo(redo)
    #expect(try #require(try await inbox.next()).rows.first?.id != target)
}

@Test func undoAfterGmailAppliedTakesTheInversePath() async throws {
    let store = makeStore()
    let target = special(0).row.id
    let token = try await store.apply(.markDone([target]))
    store.acknowledgeRemote()
    #expect(store.pendingOperationCount == 0)
    #expect(!store.serverLabels(of: try #require(special(0).detail.messages.last?.id)).contains(GmailLabelID("INBOX")))
    let redo = try #require(try await store.undo(token))
    #expect(store.pendingOperationCount == 1, "the inverse is a new operation")
    #expect(try await keys(store, .system(.inbox)).contains(target))
    _ = try await store.undo(redo)
    #expect(!(try await keys(store, .system(.inbox))).contains(target))

    let star = try await store.apply(.star([target]))
    store.beginRemoteAttempts()
    _ = try await store.undo(star)
    #expect(store.pendingOperationCount == 2, "the attempted star stays, its inverse is queued")
    store.acknowledgeRemote()
    #expect(try await window(store, .system(.allMail)).rows.first { $0.id == target }?.isStarred == false)
}

@Test func remoteFailureRevertsTheRowAndIsListed() async throws {
    let store = makeStore()
    let target = special(0).row.id
    var inbox = store.threadWindow(.system(.inbox), account: work, limit: 50).makeAsyncIterator()
    _ = try await inbox.next()
    let token = try await store.apply(.markDone([target]))
    #expect(!(try #require(try await inbox.next())).rows.contains { $0.id == target })
    store.failNextRemoteOperations(1, code: "server_503")
    store.acknowledgeRemote()
    #expect(try #require(try await inbox.next()).rows.contains { $0.id == target }, "the row reappears")
    let failures = try await first(store.failedOperations(work))
    #expect(failures.map(\.kind) == ["markDone"] && failures[0].threads == [target] && failures[0].errorCode == "server_503")
    #expect(try await first(store.counts(work)).failedOperationCount == 1)
    #expect(try await store.undo(token) == nil, "a failed operation has nothing to undo")
    try await store.dismissFailedOperation(failures[0].id)
    #expect(try await first(store.failedOperations(nil)).isEmpty)
}

@Test func localFailureChangesNothing() async throws {
    let store = makeStore()
    let before = try await window(store, .system(.inbox))
    store.failNextCommand()
    await #expect(throws: MailPortError.unavailable("injected failure")) {
        _ = try await store.apply(.markDone([before.rows[0].id]))
    }
    #expect(try await window(store, .system(.inbox)) == before)
    _ = try await store.apply(.markDone([before.rows[0].id]))
}

@Test func offlineHoldsOperationsUntilBackOnline() async throws {
    let store = makeStore(ack: .immediate, liveConnectivity: true)
    store.setOffline(true)
    let target = special(0).row.id
    _ = try await store.apply(.markDone([target]))
    #expect(store.pendingOperationCount == 1)
    #expect(!(try await keys(store, .system(.inbox))).contains(target), "the overlay applies offline")
    guard case .offline = await first(store.connectivity())?[work] else { Issue.record("expected offline"); return }
    await #expect(throws: MailPortError.unavailable("offline")) {
        _ = try await store.fetchThreadNow(work, gmailThreadID: target.gmailThreadID)
    }
    store.setOffline(false)
    #expect(store.pendingOperationCount == 0)
    #expect(try await store.fetchThreadNow(work, gmailThreadID: target.gmailThreadID) == target)
}

@Test func expiredAuthHoldsOperationsUntilReauthorized() async throws {
    let store = makeStore(ack: .immediate, liveConnectivity: true)
    store.expireAuth(work)
    #expect(try await first(store.accounts()).first?.health == .needsSignIn)
    #expect(await first(store.connectivity())?[work] == .needsReauth)
    #expect(await first(store.connectivity())?[personal] != .needsReauth)
    let row = special(0).row
    _ = try await store.apply(row.isUnread ? .markRead([row.id]) : .markUnread([row.id]))
    #expect(store.pendingOperationCount == 1)
    store.enqueueSignIn(.succeed(email: "someone.else@example.org", displayName: nil))
    await #expect(throws: AccountSetupError.self) { try await store.reauthorize(work) }
    try await store.reauthorize(work)
    #expect(try await first(store.accounts()).first?.health == .active)
    #expect(store.pendingOperationCount == 0)
}

@Test func safeModeRefusesWritesButNotReads() async throws {
    let store = makeStore(safeMode: .readOnly)
    #expect(store.safeMode() == .readOnly)
    let target = special(0).row.id
    await #expect(throws: MailPortError.blockedBySafeMode) { _ = try await store.apply(.markDone([target])) }
    await #expect(throws: MailPortError.blockedBySafeMode) {
        _ = try await store.createDraft(DraftInput(account: work, mode: .new))
    }
    await #expect(throws: MailPortError.blockedBySafeMode) {
        _ = try await store.createLabel(work, name: "X", applyTo: [])
    }
    #expect(try await keys(store, .system(.inbox)).contains(target))
    try await store.set(AppSettings.undoSendSeconds, 5)

    store.setSafeMode(.writeAllowlist)
    _ = try await store.apply(.markDone([target]))
    let draft = try #require(special(0).detail.messages.last?.id)
    let (key, _) = try await store.createDraft(DraftInput(account: work, mode: .reply, replyTo: draft))
    await #expect(throws: MailPortError.blockedBySafeMode) { _ = try await store.send(key, undoWindow: .seconds(5)) }
}

@Test func readAndStarChangeTheRow() async throws {
    let store = makeStore(ack: .immediate)
    let target = special(0).row.id
    _ = try await store.apply(.markRead([target]))
    var row = try #require(try await window(store, .system(.inbox)).rows.first { $0.id == target })
    #expect(!row.isUnread && row.unreadCount == 0)
    _ = try await store.apply(.star([target]))
    row = try #require(try await window(store, .system(.inbox)).rows.first { $0.id == target })
    #expect(row.isStarred)
    #expect(try await keys(store, .system(.starred)).contains(target))
    _ = try await store.apply(.trash([target]))
    #expect(try await keys(store, .system(.trash)).contains(target))
    #expect(!(try await keys(store, .system(.inbox))).contains(target))
    _ = try await store.apply(.untrash([target]))
    #expect(!(try await keys(store, .system(.trash))).contains(target))
    _ = try await store.apply(.markSpam([target]))
    #expect(try await keys(store, .system(.spam)).contains(target))
    _ = try await store.apply(.markNotSpam([target]))
    #expect(try await keys(store, .system(.inbox)).contains(target))
}

@Test func createLabelAppliesInOneUndoableStep() async throws {
    let store = makeStore()
    let target = special(0).row.id
    let token = try await store.createLabel(work, name: "Follow-up", applyTo: [target])
    let label = try #require(try await first(store.labels(work)).first { $0.name == "Follow-up" })
    #expect(label.kind == .user && label.totalThreads == 1)
    #expect(try await window(store, .system(.inbox)).rows.first { $0.id == target }?.userLabelIDs == [label.id])
    _ = try await store.undo(token)
    #expect(try await window(store, .system(.inbox)).rows.first { $0.id == target }?.userLabelIDs == [])
    #expect(try await first(store.labels(work)).contains { $0.name == "Follow-up" }, "the label itself stays")
    store.setOffline(true)
    _ = try await store.createLabel(work, name: "Later", applyTo: [target])
    #expect(store.labelNames(of: target).contains("Later"))
}

@Test func scheduleLabelsAreReserved() async throws {
    let store = makeStore()
    let target = special(0).row.id
    await #expect(throws: MailPortError.reservedLabel("OpenHuman/Snoozed/20261012T0900Z")) {
        _ = try await store.createLabel(work, name: "OpenHuman/Snoozed/20261012T0900Z", applyTo: [target])
    }
    let stamp = try #require(try await first(store.labels(work)).first { $0.name.hasPrefix("OpenHuman/Snoozed/2") })
    await #expect(throws: MailPortError.reservedLabel(stamp.name)) {
        _ = try await store.apply(.modifyLabels([target], add: [stamp.labelID], remove: []))
    }
    await #expect(throws: MailPortError.notFound("label")) {
        _ = try await store.apply(.modifyLabels([target], add: [GmailLabelID("Label_404404")], remove: []))
    }
}

@Test func delayedAcknowledgementSettlesOnItsOwn() async throws {
    let store = makeStore(ack: .after(.milliseconds(5)))
    _ = try await store.apply(.markDone([special(0).row.id]))
    _ = try await first(store.threadWindow(.system(.allMail), account: work, limit: 500)) { window in
        window.rows.first { $0.id == special(0).row.id }?.hasPendingChanges == false
    }
    #expect(store.pendingOperationCount == 0)
}
