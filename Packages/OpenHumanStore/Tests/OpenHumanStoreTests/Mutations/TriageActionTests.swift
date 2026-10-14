import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct TriageActionTests {
    @Test func trashLeavesEveryViewButTrashAndUntrashOnlyTakesTrashedMessages() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: ["SPAM"]),
                      .fixture("a3", thread: "t1", minutes: 3, labels: ["DRAFT"]),
                      .fixture("b1", thread: "t2", minutes: 4, labels: ["INBOX"])])
        let t1 = try f.ref("t1")
        let receipt = try f.store.apply(.trash([t1]), origin: .app)
        let op = try f.op(try #require(receipt.operationIDs.first))
        #expect(op.kind == .trash && op.coalesceKey == nil && receipt.undo == .untrash([t1]))
        #expect(op.payload == .trash(ids: [GmailMessageID("a1"), GmailMessageID("a2")]))
        #expect(try f.inbox() == ["t2"] && f.view(.trash) == ["t1"] && f.view(.spam).isEmpty)
        #expect(try f.effective("a1") == ["TRASH"] && f.effective("a2") == ["TRASH"])
        try f.drain()
        #expect(try f.server("a1") == ["TRASH"])

        let back = try f.store.apply(.untrash([t1]), origin: .app)
        let untrash = try f.op(try #require(back.operationIDs.first))
        #expect(untrash.payload == .untrash(ids: [GmailMessageID("a1"), GmailMessageID("a2")]))
        #expect(try f.view(.trash).isEmpty && Set(f.inbox()) == ["t1", "t2"])
        #expect(try back.operationIDs.map { try f.op($0).kind } == [.untrash, .modifyLabels])
        #expect(try f.op(back.operationIDs[1]).dependsOn == untrash.id && back.undo == .trash([t1]))
        #expect(try f.store.apply(.trash([try f.ref("t2")]), origin: .app).operationIDs.count == 1)
        #expect(try f.store.apply(.trash([try f.ref("t2")]), origin: .app).operationIDs.isEmpty)
    }

    @Test func spamAndNotSpam() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let spam = try f.store.apply(.markSpam([refs[0]]), origin: .app)
        let op = try f.op(try #require(spam.operationIDs.first))
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("SPAM")],
                                            remove: [GmailLabelID("INBOX")], addNames: []))
        #expect(try f.view(.spam) == ["t1"] && f.inbox() == ["t2"] && spam.undo == .markNotSpam([refs[0]]))
        try f.drain()
        let notSpam = try f.store.apply(.markNotSpam([refs[0]]), origin: .app)
        #expect(try f.op(try #require(notSpam.operationIDs.first)).payload
            == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("INBOX")], remove: [GmailLabelID("SPAM")], addNames: []))
        #expect(try Set(f.inbox()) == ["t1", "t2"] && f.view(.spam).isEmpty)
    }

    @Test func starMarksTheLatestVisibleMessageAndUnstarClearsEveryStar() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX", "STARRED"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: ["INBOX"]),
                      .fixture("a3", thread: "t1", minutes: 3, labels: ["TRASH"])])
        let t1 = try f.ref("t1")
        let star = try f.store.apply(.star([t1]), origin: .app)
        #expect(try f.op(try #require(star.operationIDs.first)).payload
            == .modifyLabels(ids: [GmailMessageID("a2")], add: [GmailLabelID("STARRED")], remove: [], addNames: []))
        #expect(try f.store.apply(.star([t1]), origin: .app).operationIDs.isEmpty)
        let unstar = try f.store.apply(.unstar([t1]), origin: .app)
        #expect(try f.op(try #require(unstar.operationIDs.first)).payload
            == .modifyLabels(ids: [GmailMessageID("a1"), GmailMessageID("a2")], add: [], remove: [GmailLabelID("STARRED")],
                             addNames: []))
        #expect(try f.store.thread(t1)?.isStarred == false && f.view(.starred).isEmpty)
        #expect(unstar.undo == .star([t1]))
    }

    @Test func readAndUnreadUseTheVisibleMessagesOrTheTrashViewsOnes() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX", "UNREAD"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: ["INBOX", "UNREAD"]),
                      .fixture("z1", thread: "tz", minutes: 3, labels: ["TRASH", "UNREAD"])])
        let read = try f.store.apply(.markRead([try f.ref("t1"), try f.ref("tz")]), origin: .app)
        #expect(read.operationIDs.count == 1)
        #expect(try f.op(read.operationIDs[0]).payload == .modifyLabels(
            ids: ["a1", "a2", "z1"].map { GmailMessageID($0) }, add: [], remove: [GmailLabelID("UNREAD")], addNames: []))
        #expect(try f.store.label(account: f.account, key: "INBOX")?.unreadThreads == 0)
        #expect(try f.store.thread(try f.ref("tz"))?.unreadCount == 0)
        let unread = try f.store.apply(.markUnread([try f.ref("t1")]), origin: .app)
        #expect(try f.store.label(account: f.account, key: "INBOX")?.unreadThreads == 1 && unread.undo == .markRead([try f.ref("t1")]))
    }

    @Test func genericLabelEditsResolveIdsAndNamesAndRefuseReservedOnes() throws {
        let f = try MutationFixture()
        try f.labels([("L_c", "Clients"), ("L_s9", snooze9), ("L_mark", "OpenHuman/Snoozed"), ("L_bad", "OpenHuman/Snoozed/oops"),
                      ("L_agent", OHGmailLabels.agent)])
        let refs = try f.seed(1)
        let byName = try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("Clients")], remove: []), origin: .app)
        #expect(try f.op(byName.operationIDs[0]).payload
            == .modifyLabels(ids: [GmailMessageID("m1")], add: [GmailLabelID("L_c")], remove: [], addNames: []))
        #expect(try f.store.thread(refs[0])?.userLabelIDs.count == 1)
        #expect(byName.undo == .modifyLabels(refs, add: [], remove: [GmailLabelID("Clients")]))
        #expect(try f.store.apply(.modifyLabels(refs, add: [], remove: [GmailLabelID("Nope")]), origin: .app).operationIDs.isEmpty)
        #expect(throws: StoreError.notFound("label Nope")) {
            try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("Nope")], remove: []), origin: .app)
        }
        for reserved in ["L_s9", snooze9, "L_mark", "OpenHuman/Scheduled", "OpenHuman/Scheduled/20261012T0900Z", "L_bad"] {
            #expect(throws: StoreError.self) {
                try f.store.apply(.modifyLabels(refs, add: [GmailLabelID(reserved)], remove: []), origin: .app)
            }
            #expect(throws: StoreError.self) {
                try f.store.apply(.modifyLabels(refs, add: [], remove: [GmailLabelID(reserved)]), origin: .app)
            }
            #expect(throws: StoreError.self) {
                try f.store.apply(.modifyMessageLabels(f.account, [GmailMessageID("m1")], add: [GmailLabelID(reserved)],
                                                       remove: []), origin: .app)
            }
        }
        #expect(throws: StoreError.reservedLabel(snooze9)) {
            try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("L_s9")], remove: []), origin: .app)
        }
        #expect(try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("L_agent")], remove: []), origin: .app).operationIDs.count == 1)
        for bad in ["DRAFT", "SENT", "oh:allmail"] {
            #expect(throws: StoreError.self) { try f.store.apply(.modifyLabels(refs, add: [GmailLabelID(bad)], remove: []), origin: .app) }
        }
        #expect(throws: StoreError.self) {
            try f.store.apply(.modifyLabels(refs, add: [GmailLabelID("L_c")], remove: [GmailLabelID("Clients")]), origin: .app)
        }
        #expect(throws: StoreError.reservedLabel("OpenHuman/Snoozed/20261012T0900Z")) {
            try f.store.apply(.createLabel(f.account, name: "OpenHuman/Snoozed/20261012T0900Z", applyTo: refs), origin: .app)
        }
    }

    @Test func messageLabelEditsSendUnknownIdsButLinkOnlyKnownOnes() throws {
        let f = try MutationFixture()
        try f.labels([("L_c", "Clients")])
        _ = try f.seed(1)
        let receipt = try f.store.apply(.modifyMessageLabels(f.account, [GmailMessageID("m1"), GmailMessageID("elsewhere")],
                                                             add: [GmailLabelID("L_c")], remove: []), origin: .cli)
        let op = try f.op(receipt.operationIDs[0])
        #expect(op.payload == .modifyLabels(ids: [GmailMessageID("m1"), GmailMessageID("elsewhere")],
                                            add: [GmailLabelID("L_c")], remove: [], addNames: []))
        #expect(try op.origin == .cli && f.links(op.id) == 1)
        #expect(receipt.undo == .modifyMessageLabels(f.account, [GmailMessageID("m1"), GmailMessageID("elsewhere")],
                                                     add: [], remove: [GmailLabelID("L_c")]))
        #expect(op.coalesceKey != nil)
    }

    @Test func aSchedulerMessageLabelEditHasNoCoalesceKey() throws {
        let f = try MutationFixture()
        try f.labels([("L_m", "OpenHuman/Muted")])
        _ = try f.seed(1)
        let receipt = try f.store.apply(.modifyMessageLabels(f.account, [GmailMessageID("m1")], add: [GmailLabelID("L_m")],
                                                             remove: [GmailLabelID("INBOX")]), origin: .scheduler)
        #expect(try f.op(receipt.operationIDs[0]).coalesceKey == nil)
    }

    @Test func createLabelWorksOfflineAndShowsWhenTheLabelRowArrives() throws {
        let f = try MutationFixture()
        let refs = try f.seed(2)
        let receipt = try f.store.apply(.createLabel(f.account, name: " Clients ", applyTo: [refs[0]]), origin: .app)
        #expect(receipt.operationIDs.count == 2)
        let create = try f.op(receipt.operationIDs[0]), modify = try f.op(receipt.operationIDs[1])
        #expect(create.payload == .createLabel(name: "Clients") && create.dependsOn == nil)
        #expect(modify.payload == .modifyLabels(ids: [GmailMessageID("m1")], add: [], remove: [], addNames: ["Clients"]))
        #expect(modify.dependsOn == create.id && modify.coalesceKey == "labels:\(f.account.rawValue):||Clients")
        #expect(receipt.undo == .modifyLabels([refs[0]], add: [], remove: [GmailLabelID("Clients")]))
        #expect(try f.claim().map(\.id) == [create.id])
        try f.store.complete(create.id, outcome: .labelCreated(LabelUpsert(gmailLabelID: GmailLabelID("L_new"), name: "Clients",
                                                                           type: "user")))
        #expect(try f.effective("m1").contains("L_new"))
        #expect(try f.store.thread(refs[0])?.userLabelIDs.count == 1)
        try f.drain()
        #expect(try f.server("m1").contains("L_new"))
        let again = try f.store.apply(.createLabel(f.account, name: "Clients", applyTo: [refs[1]]), origin: .app)
        #expect(try again.operationIDs.map { try f.op($0).kind } == [.modifyLabels])
        #expect(try f.store.apply(.createLabel(f.account, name: "Clients", applyTo: []), origin: .app).operationIDs.isEmpty)
        #expect(throws: StoreError.self) { try f.store.apply(.createLabel(f.account, name: "  ", applyTo: []), origin: .app) }
        let undone = try #require(try f.store.undo(receipt, origin: .app))
        #expect(try f.op(undone.operationIDs[0]).payload
            == .modifyLabels(ids: [GmailMessageID("m1")], add: [], remove: [GmailLabelID("L_new")], addNames: []))
        #expect(try f.store.label(account: f.account, key: "L_new") != nil)
    }

    @Test func undoOfAPendingLabelCreationCancelsBothOpsAndRedoCreatesItAgain() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.createLabel(f.account, name: "Clients", applyTo: refs), origin: .app)
        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(redo.operationIDs.isEmpty && redo.undo == .createLabel(f.account, name: "Clients", applyTo: refs))
        #expect(try receipt.operationIDs.map { try f.op($0).status } == [.cancelled, .cancelled])
        let again = try #require(try f.store.undo(redo, origin: .app))
        #expect(again.operationIDs.count == 2)
        #expect(try f.ops([.pending]).map(\.kind) == [.createLabel, .modifyLabels])
    }

    @Test func triageNeverTouchesAReminder() throws {
        let f = try MutationFixture()
        try f.labels([("L_c", "Clients")])
        let refs = try f.seed(1)
        _ = try f.store.apply(.setReminder(refs[0], dueAt: nine, condition: .always), origin: .app)
        for action: MailAction in [.archive(refs), .markRead(refs), .star(refs), .modifyLabels(refs, add: [GmailLabelID("L_c")], remove: []),
                                   .markSpam(refs), .markNotSpam(refs), .trash(refs), .untrash(refs), .moveToInbox(refs)] {
            _ = try f.store.apply(action, origin: .app)
            #expect(try f.reminders("t1").map { $0["state"] as String } == ["active"], "\(action)")
        }
        try f.drain()
        #expect(try f.store.thread(refs[0])?.reminderAt == nine)
    }

    @Test func undoAfterTheDrainRestoresOnlyTheMessagesTheActionChanged() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: ["INBOX"]),
                      .fixture("a3", thread: "t1", minutes: 3, labels: ["INBOX", "UNREAD"])])
        let t1 = try f.ref("t1")
        let receipt = try f.store.apply(.markRead([t1]), origin: .app)
        #expect(receipt.undo == .markUnread([t1]))
        try f.drain()
        let undone = try #require(try f.store.undo(receipt, origin: .app))
        try f.drain()
        #expect(try f.server("a1") == ["INBOX"] && f.server("a2") == ["INBOX"] && f.server("a3") == ["INBOX", "UNREAD"])
        _ = try #require(try f.store.undo(undone, origin: .app))
        #expect(try f.effective("a3") == ["INBOX"])
    }

    @Test(arguments: [false, true]) func undoOfAMuteTakesBackWhatTheRuleMutedSince(drained: Bool) throws {
        let f = try MutationFixture()
        try f.labels([("L_m", "OpenHuman/Muted")])
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: drained ? ["L_m"] : ["INBOX"])])
        let t1 = try f.ref("t1")
        let mute = try f.store.apply(.modifyLabels([t1], add: [GmailLabelID("L_m")], remove: [GmailLabelID("INBOX")]),
                                     origin: .app)
        if drained { try f.drain() }
        try f.upsert([.fixture("a3", thread: "t1", minutes: 3, labels: ["INBOX"])])
        _ = try f.store.apply(.modifyMessageLabels(f.account, [GmailMessageID("a3")], add: [GmailLabelID("L_m")],
                                                   remove: [GmailLabelID("INBOX")]), origin: .scheduler)
        let redo = try #require(try f.store.undo(mute, origin: .app))
        for id in ["a1", "a2", "a3"] { #expect(try f.effective(id) == ["INBOX"], "\(id)") }
        try f.drain()
        for id in ["a1", "a2", "a3"] { #expect(try f.server(id) == ["INBOX"], "\(id)") }
        _ = try #require(try f.store.undo(redo, origin: .app))
        for id in ["a1", "a2", "a3"] { #expect(try f.effective(id) == ["L_m"], "redo \(id)") }
    }

    @Test func aMutedConversationMovedBackToTheInboxKeepsItsPlaceWhenTheRuleMutesAReply() throws {
        let f = try MutationFixture()
        try f.labels([("L_m", "OpenHuman/Muted")])
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX", "L_m"]),
                      .fixture("b1", thread: "t2", minutes: 2, labels: ["INBOX"]),
                      .fixture("c1", thread: "t3", minutes: 2, labels: ["L_m"])])
        func mutedView() throws -> [String] {
            try f.store.threadPage(view: .label(f.account, GmailLabelID("L_m")), after: nil, limit: 10).items
                .map(\.ref.gmailThreadID.rawValue)
        }
        #expect(try f.inbox() == ["t2", "t1"] && mutedView() == ["t3", "t1"])
        try f.upsert([.fixture("a2", thread: "t1", minutes: 3, labels: ["INBOX"])])
        _ = try f.store.apply(.modifyMessageLabels(f.account, [GmailMessageID("a2")], add: [GmailLabelID("L_m")],
                                                   remove: [GmailLabelID("INBOX")]), origin: .scheduler)
        #expect(try f.inbox() == ["t2", "t1"], "the muted reply does not move it up")
        #expect(try mutedView() == ["t1", "t3"])
        try f.upsert([.fixture("a3", thread: "t1", minutes: 4, labels: ["SENT"])])
        #expect(try f.inbox() == ["t1", "t2"])
    }

    @Test func undoOfABatchLeavesTheConversationsThatWereAlreadyThere() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["INBOX", "UNREAD"]),
                      .fixture("b1", thread: "t2", minutes: 2, labels: ["INBOX"])])
        let receipt = try f.store.apply(.markRead([try f.ref("t1"), try f.ref("t2")]), origin: .app)
        try f.drain()
        _ = try #require(try f.store.undo(receipt, origin: .app))
        try f.drain()
        #expect(try f.server("a1") == ["INBOX", "UNREAD"] && f.server("b1") == ["INBOX"])
    }

    @Test func undoOfAStarRemovesOnlyThatStar() throws {
        let f = try MutationFixture()
        try f.upsert([.fixture("a1", thread: "t1", minutes: 1, labels: ["TRASH", "STARRED"]),
                      .fixture("a2", thread: "t1", minutes: 2, labels: ["INBOX"])])
        let receipt = try f.store.apply(.star([try f.ref("t1")]), origin: .app)
        try f.drain()
        _ = try #require(try f.store.undo(receipt, origin: .app))
        try f.drain()
        #expect(try f.server("a1") == ["TRASH", "STARRED"] && f.server("a2") == ["INBOX"])
    }
}

@Suite struct UndoMatrixTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var make: @Sendable (ThreadRef) -> MailAction
        var seedLabels: [String]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "archive", make: { .archive([$0]) }, seedLabels: ["INBOX", "UNREAD"]),
        Case(name: "moveToInbox", make: { .moveToInbox([$0]) }, seedLabels: ["UNREAD"]),
        Case(name: "trash", make: { .trash([$0]) }, seedLabels: ["INBOX"]),
        Case(name: "markRead", make: { .markRead([$0]) }, seedLabels: ["INBOX", "UNREAD"]),
        Case(name: "markUnread", make: { .markUnread([$0]) }, seedLabels: ["INBOX"]),
        Case(name: "star", make: { .star([$0]) }, seedLabels: ["INBOX"]),
        Case(name: "unstar", make: { .unstar([$0]) }, seedLabels: ["INBOX", "STARRED"]),
        Case(name: "markSpam", make: { .markSpam([$0]) }, seedLabels: ["INBOX"]),
        Case(name: "label", make: { .modifyLabels([$0], add: [GmailLabelID("L_c")], remove: []) }, seedLabels: ["INBOX"]),
    ]

    private func setup(_ c: Case) throws -> (MutationFixture, ThreadRef, Set<String>) {
        let f = try MutationFixture()
        try f.labels([("L_c", "Clients")])
        try f.upsert([.fixture("m1", thread: "t1", labels: c.seedLabels)])
        return (f, try f.ref("t1"), try f.effective("m1"))
    }

    @Test(arguments: cases) func pendingUndoCancelsAndRedoReapplies(_ c: Case) throws {
        let (f, t1, before) = try setup(c)
        let receipt = try f.store.apply(c.make(t1), origin: .app)
        let after = try f.effective("m1")
        #expect(after != before && receipt.operationIDs.count == 1)
        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(redo.operationIDs.isEmpty && redo.undo == c.make(t1))
        #expect(try f.effective("m1") == before && f.op(receipt.operationIDs[0]).status == .cancelled)
        let again = try #require(try f.store.undo(redo, origin: .app))
        #expect(try again.operationIDs.count == 1 && f.effective("m1") == after)
        _ = try f.store.undo(again, origin: .app)
        #expect(try f.effective("m1") == before && f.ops([.pending, .inFlight]).isEmpty)
    }

    @Test(arguments: cases) func offlineReleaseIsStillCancellable(_ c: Case) throws {
        let (f, t1, before) = try setup(c)
        let receipt = try f.store.apply(c.make(t1), origin: .app)
        let op = try #require(try f.claim().first)
        try f.store.release(op.id, retryAt: Date().addingTimeInterval(30))
        let redo = try #require(try f.store.undo(receipt, origin: .app))
        #expect(try redo.operationIDs.isEmpty && f.effective("m1") == before)
    }

    @Test(arguments: cases) func inFlightSucceededRetryingOrCollectedUndoesWithTheInverse(_ c: Case) throws {
        for stage in ["in flight", "succeeded", "retrying", "collected"] {
            let (f, t1, before) = try setup(c)
            let receipt = try f.store.apply(c.make(t1), origin: .app)
            let op = try #require(try f.claim().first)
            switch stage {
            case "succeeded": try f.store.complete(op.id, outcome: .labelsApplied)
            case "retrying": try f.store.fail(op.id, code: "server", message: "503", retryAt: Date().addingTimeInterval(60))
            case "collected":
                try f.store.complete(op.id, outcome: .labelsApplied)
                try f.store.garbageCollectOperations(now: Date().addingTimeInterval(2 * 3600))
                #expect(try f.store.operation(op.id) == nil)
            default: break
            }
            let undone = try #require(try f.store.undo(receipt, origin: .app), "\(stage)")
            #expect(!undone.operationIDs.isEmpty && undone.undo != nil, "\(stage)")
            #expect(try f.effective("m1") == before, "\(c.name) \(stage)")
            if stage == "retrying" || stage == "in flight" { try f.store.complete(op.id, outcome: .labelsApplied) }
            try f.drain(now: Date().addingTimeInterval(120))
            #expect(try f.server("m1") == before && f.effective("m1") == before, "\(c.name) \(stage)")
            let redone = try #require(try f.store.undo(undone, origin: .app))
            #expect(try !redone.operationIDs.isEmpty && f.effective("m1") != before, "\(c.name) \(stage)")
        }
    }

    @Test func permanentlyFailedOrSchedulerOpsHaveNothingToUndo() throws {
        let f = try MutationFixture()
        let refs = try f.seed(1)
        let receipt = try f.store.apply(.archive(refs), origin: .app)
        _ = try f.claim()
        try f.store.fail(receipt.operationIDs[0], code: "bad_request", message: "no", retryAt: nil)
        #expect(try f.store.undo(receipt, origin: .app) == nil)
        let scheduler = ActionReceipt(operationIDs: try f.store.apply(.archive(refs), origin: .scheduler).operationIDs, undo: nil)
        #expect(try f.store.undo(scheduler, origin: .app) == nil)
        #expect(try f.op(scheduler.operationIDs[0]).status == .pending)
    }
}
