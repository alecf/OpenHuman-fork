import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ImportanceActionTests {
    func fixture(location: MailLocation? = .system(.inbox),
                 options: FakeMailStore.Options = .init(remoteAck: .immediate)) async -> ActionFixture {
        let f = ActionFixture(corpus: .make(threadCount: 12, now: fixedNow), options: options, location: location)
        await f.loaded()
        return f
    }

    var rules: (ActionFixture) -> FakeImportanceRules { { $0.env.importance as! FakeImportanceRules } }

    @Test func alwaysImportantFromSenderAppliesWithUndoAndRedo() async throws {
        let f = await fixture()
        let sender = try #require(f.router.actionContext().sender)
        #expect(await f.run(.alwaysImportantSender))
        await f.toast("Always important from \(sender)")
        #expect(rules(f).allRules.map(\.kind) == [.alwaysSender])
        #expect(rules(f).allRules.first?.value == sender)
        #expect(f.env.undo?.stack.last?.undoer != nil, "undone through the importance port, not the mail commands")
        #expect(await f.run(.undo))
        #expect(rules(f).allRules.isEmpty)
        #expect(await f.run(.redo))
        #expect(rules(f).allRules.map(\.kind) == [.alwaysSender])
    }

    @Test func neverImportantReplacesAlwaysAndWhyIsThisHereExplains() async throws {
        let f = await fixture()
        let sender = try #require(f.router.actionContext().sender)
        #expect(await f.run(.alwaysImportantSender))
        #expect(await f.run(.explainPlacement))
        await f.toast("In Important: Always important from \(sender)")
        #expect(f.registry.importanceActions?.lastExplanation?.explanation.ruleID != nil)
        #expect(await f.run(.neverImportant))
        #expect(rules(f).allRules.map(\.kind) == [.neverSender], "never replaces always for the same sender")
        #expect(await f.run(.explainPlacement))
        await f.toast("In Other: Never important from \(sender)")
        #expect(await f.run(.undo))
        #expect(rules(f).allRules.map(\.kind) == [.alwaysSender], "undo restores the replaced rule")
    }

    @Test func domainAndNotAPitch() async throws {
        let f = await fixture()
        let domain = try #require(f.router.actionContext().senderDomain)
        #expect(await f.run(.alwaysImportantDomain))
        await f.toast("Always important from \(domain)")
        #expect(await f.run(.notAPitch))
        #expect(Set(rules(f).allRules.map(\.kind)) == [.alwaysDomain, .notPitch])
        #expect(await f.run(.explainPlacement))
        await f.toast("In Important: Always important from \(domain)")
    }

    @Test func neverImportantFromTheDomainAndTheSenderStaysImportant() async throws {
        #expect(ActionCatalog.descriptor(.neverImportantDomain)?.shortcutHint == "-")
        #expect(ActionCatalog.descriptor(.alwaysImportantSender)?.shortcutHint == "+")
        let f = await fixture()
        let context = f.router.actionContext()
        let sender = try #require(context.sender)
        let domain = try #require(context.senderDomain)
        #expect(f.registry.availability(.neverImportantDomain, host: f.router) == .enabled)
        #expect(await f.run(.neverImportantDomain))
        await f.toast("Never important from \(domain)")
        #expect(rules(f).allRules.map(\.kind) == [.neverDomain])
        #expect(rules(f).allRules.first?.value == domain)
        #expect(await f.run(.explainPlacement))
        await f.toast("In Other: Never important from \(domain)")

        #expect(await f.run(.alwaysImportantSender))
        #expect(Set(rules(f).allRules.map(\.kind)) == [.neverDomain, .alwaysSender])
        #expect(await f.run(.explainPlacement))
        await f.toast("In Important: Always important from \(sender)")

        #expect(await f.run(.undo))
        #expect(await f.run(.undo))
        #expect(rules(f).allRules.isEmpty, "both rules undone, newest first")
    }

    @Test func removeFromThisSplitOnlyOnASplit() async throws {
        let inbox = await fixture()
        #expect(inbox.registry.availability(.removeFromSplit, host: inbox.router) == .hidden)
        let f = await fixture(location: nil)
        await eventually { if case .split = f.router.location { true } else { false } }
        guard case .split(let split) = f.router.location else {
            Issue.record("not on a split: \(String(describing: f.router.location))")
            return
        }
        #expect(await f.run(.removeFromSplit))
        await f.toast("Removed from Important")
        #expect(rules(f).allRules.first?.kind == .excludeFromSplit)
        #expect(rules(f).allRules.first?.split == split)
    }

    @Test func hiddenWithoutThePort() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow))
        let env = AppEnvironment(data: store, commands: store, isFake: true, featureFlags: FeatureFlags())
        let router = AppRouter(environment: env)
        router.start()
        await eventually { router.list?.rows.count == 3 }
        #expect(env.actions.contains(.alwaysImportantSender), "the module is on")
        #expect(env.actions.availability(.alwaysImportantSender, host: router) == .hidden, "but no port: hidden")
    }

    @Test func importanceChangeValuesAreLowercased() {
        let change = ImportanceChange(kind: .alwaysSender, account: AccountID(1), value: "Dana@Acme.example")
        #expect(change.value == "dana@acme.example")
    }

    @Test func rulesStreamFollowsChanges() async throws {
        let port = FakeImportanceRules()
        var iterator = port.rules(AccountID(1)).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let token = try await port.apply(ImportanceChange(kind: .alwaysDomain, account: AccountID(1), value: "acme.example"))
        #expect(try await iterator.next()?.map(\.value) == ["acme.example"])
        let redo = try await port.undo(token)
        #expect(try await iterator.next() == [])
        #expect(redo != nil)
        #expect(try await port.undo(token) == nil, "an undone change has nothing left to undo")
    }
}

@Suite struct PendingOverlayTests {
    struct Row: Equatable { var key: Int; var starred: Bool }
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let rows = [Row(key: 1, starred: false), Row(key: 2, starred: false), Row(key: 3, starred: false)]

    func applied(_ overlay: PendingOverlay<Int, Bool>) -> [Row] {
        overlay.apply(to: rows, key: \.key) { row, starred in Row(key: row.key, starred: starred) }
    }

    @Test func hideAndPatchApplySynchronously() {
        var overlay = PendingOverlay<Int, Bool>()
        overlay.hide([1], operation: UUID(), now: now)
        overlay.patch(2, true, operation: UUID(), now: now)
        #expect(applied(overlay) == [Row(key: 2, starred: true), Row(key: 3, starred: false)])
        #expect(overlay.isHidden(1) && overlay.patch(for: 2) == true)
    }

    @Test func aFailureRevertsOnlyItsOwnOperation() {
        var overlay = PendingOverlay<Int, Bool>()
        let done = UUID(), star = UUID()
        overlay.hide([1, 2], operation: done, now: now)
        overlay.patch(3, true, operation: star, now: now)
        overlay.revert(done)
        #expect(applied(overlay) == [rows[0], rows[1], Row(key: 3, starred: true)])
        overlay.revert(star)
        #expect(overlay.isEmpty)
    }

    @Test func snapshotsSettleEntriesAndTenSecondsExpireThem() {
        var overlay = PendingOverlay<Int, Bool>()
        overlay.hide([1], operation: UUID(), now: now)
        overlay.patch(2, true, operation: UUID(), now: now)
        overlay.settle { key, _ in key == 1 }
        #expect(!overlay.isHidden(1) && overlay.patch(for: 2) == true)
        overlay.expire(asOf: now.addingTimeInterval(9.9))
        #expect(!overlay.isEmpty)
        overlay.expire(asOf: now.addingTimeInterval(PendingOverlay<Int, Bool>.lifetime))
        #expect(overlay.isEmpty)
    }
}

@MainActor
@Suite struct UndoAndStorageTests {
    @Test func entriesCarryTheirThreadsAndPort() async throws {
        let port = FakeUndoPort()
        let other = FakeUndoPort()
        let undo = UndoCoordinator(commands: port, notices: nil)
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        let entry = try await undo.perform("Always important", threads: [key], via: other) { other.markDone("x") }
        #expect(entry.threads == [key] && undo.nextUndo?.id == entry.id)
        await undo.undoLast()
        #expect(other.calls == ["done:x"] && port.calls.isEmpty, "undone through the entry's own port")
        await undo.redoLast()
        #expect(other.calls == ["done:x", "inbox:x"])
        #expect(undo.stack.last?.threads == [key])
    }

    @Test func recentsRankAndPersist() throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_790_000_000))
        let store = InMemoryRecentActionsStore()
        let recents = RecentActions(store: store) { clock.withLock { $0 } }
        recents.record(.markDone)
        clock.withLock { $0 = $0.addingTimeInterval(1) }
        recents.record(.trash)
        recents.record(.markDone)
        #expect(recents.recent() == [.markDone, .trash])
        #expect(recents.boost(.markDone) > recents.boost(.trash))
        #expect(recents.boost(.spam) == 0)
        #expect(RecentActions(store: store).recent() == [.markDone, .trash], "kept in the store")
        for n in 0..<60 { recents.record(ActionID("test.a\(n)")) }
        #expect(recents.uses.count == RecentActions.limit)
    }

    @Test func userDefaultsStoresRoundTrip() throws {
        let suite = ScopedDefaults("dev.openhuman.mail.tests.actions")
        defer { suite.cleanup() }
        let keymaps = UserDefaultsKeymapStore(suiteName: suite.name)
        #expect(keymaps.load() == nil)
        let overrides = KeymapOverrides(bindings: ["thread.done": ["y"]])
        keymaps.save(overrides)
        #expect(keymaps.load() == overrides)
        let recents = UserDefaultsRecentActionsStore(suiteName: suite.name)
        recents.save([RecentActionUse(id: .markDone, count: 2, lastUsed: Date(timeIntervalSince1970: 1))])
        #expect(recents.load().map(\.id) == [.markDone])
        #expect(UserDefaultsKeymapStore.key.hasPrefix("dev.openhuman.mail."))
        #expect(InMemoryKeymapStore(overrides).load() == overrides)
    }

    @Test func everyPostedToastReachesTheAnnouncementHook() {
        let notices = NoticeCenter(autoExpire: false)
        var announced: [String] = []
        notices.onPost = { announced.append($0.message) }
        notices.post("Marked done", style: .undo)
        notices.post("Couldn't mark 1 conversation done", style: .error)
        #expect(announced == ["Marked done", "Couldn't mark 1 conversation done"])
    }
}
