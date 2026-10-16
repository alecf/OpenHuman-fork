import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

final class IntentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = fixedNow
    private var sleeps = 0
    var now: Date { lock.withLock { current } }
    var sleepCount: Int { lock.withLock { sleeps } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func slept() { lock.withLock { sleeps += 1 } }
}

@MainActor
final class IntentFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let recorder: RecordingCommands
    let router: AppRouter
    let links: DeepLinkRouter
    let intents: IntentActions
    let clock = IntentClock()
    let active = ActiveFlag()
    var asked: [String] = []
    var answer = true

    static let work = AccountID(1)
    static let personal = AccountID(2)

    init(flags: FeatureFlags = FeatureFlags(), enabled: Bool = true,
         allowChanges: Bool = true, startWindow: Bool = true) {
        store = FakeMailStore(corpus: .rich(threadCount: 40, now: fixedNow),
                              options: .init(remoteAck: .immediate, now: { fixedNow }))
        recorder = RecordingCommands(store)
        env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: true,
                             featureFlags: flags)
        let flag = active
        env.installPlatform(SystemPlatform(notifier: FakeSystemNotifier(authorization: .authorized), dock: FakeDockBadge(),
                                           loginItem: FakeLoginItem(), urlOpener: FakeURLOpener(),
                                           isAppActive: { false }, showMainWindow: { flag.windowShows += 1 }))
        router = env.router
        _ = env.compose
        let window = router
        links = DeepLinkRouter(router: { window })
        intents = IntentActions(router: { window }, links: links)
        let clock = self.clock
        intents.now = { clock.now }
        intents.sleep = { _ in clock.slept() }
        preferences.isEnabled = enabled
        preferences.allowMailChanges = allowChanges
        if startWindow { router.start() }
    }

    var preferences: IntentPreferences { IntentPreferences(defaults: env.system.preferences.defaults) }

    func loaded() async {
        await eventually { router.accounts.count == 2 && router.list?.state == .loaded }
    }

    func inbox(_ account: AccountID, _ count: Int = 5) async throws -> [ThreadRow] {
        Array(try #require(try await first(store.threadWindow(.system(.inbox), account: account, limit: count))).rows)
    }

    func id(_ row: ThreadRow) -> String { SpotlightIdentifier.make(row.id) }

    var confirm: IntentConfirmation {
        { [weak self] prompt in
            guard let self else { return false }
            self.asked.append(prompt)
            return self.answer
        }
    }

    var writes: [String] { recorder.calls.filter { ReviewQueueTests.mutations.contains($0) || $0 == "apply" } }

    func refusal(_ body: () async throws -> Void) async -> IntentError? {
        do {
            try await body()
            return nil
        } catch let error as IntentError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }
}

@MainActor
@Suite(.serialized) struct IntentActionsTests {
    @Test func countUnreadIsTheDockBadgeNumber() async throws {
        let f = IntentFixture()
        await f.loaded()
        var important = 0
        var inbox = 0
        for account in [IntentFixture.work, IntentFixture.personal] {
            let counts = try #require(try await first(f.store.counts(account)))
            important += counts.importantUnread ?? 0
            inbox += counts.inboxUnread
            #expect(try await f.intents.countUnread(account: String(account.rawValue), kind: .important)
                    == (counts.importantUnread ?? 0))
        }
        #expect(try await f.intents.countUnread(account: nil, kind: .important) == important)
        #expect(try await f.intents.countUnread(account: nil, kind: .inbox) == inbox)
        let badge = DockBadgeModel(data: f.store, badge: FakeDockBadge(), preferences: f.env.system.preferences)
        badge.start()
        await eventually { badge.total == important }
        badge.stop()
        #expect(f.recorder.calls.isEmpty, "a count is a local read")
        #expect(await f.refusal { _ = try await f.intents.countUnread(account: "99", kind: .inbox) } == .unknownAccount)
    }

    @Test func findConversationsIsLocalClampedAndSharesNoContent() async throws {
        let f = IntentFixture()
        await f.loaded()
        let secret = EmailAddress(name: "Quill Marker", email: "quill@secret-sender.example")
        f.store.deliverMessage(account: IntentFixture.work, from: secret, subject: "zqxmarker budget",
                               text: "BODYMARKER please keep this private", important: true)
        for n in 0..<24 {
            f.store.deliverMessage(account: IntentFixture.personal, from: secret, subject: "zqxbatch \(n)",
                                   text: "BODYMARKER batch")
        }
        let found = try await f.intents.findConversations("zqxmarker", account: nil, limit: 5, importantOnly: false)
        let hit = try #require(found.first)
        #expect(found.count == 1)
        #expect(hit.senderName == "Quill Marker")
        #expect(hit.subject.isEmpty, "subjects are opt-in")
        #expect(hit.title == "Mail from Quill Marker")
        #expect(hit.accountName == "Work")
        #expect(SpotlightIdentifier.parse(hit.id)?.account == IntentFixture.work)
        let shared = "\(hit.id) \(hit.link.absoluteString) \(hit.senderName) \(hit.subject) \(hit.accountName)"
        for marker in ["zqxmarker", "BODYMARKER", "secret-sender", "quill@"] {
            #expect(!shared.contains(marker), "\(marker) left Mail")
        }
        f.preferences.shareSubjects = true
        let withSubject = try #require(try await f.intents.findConversations("zqxmarker", account: "1", limit: 5,
                                                                            importantOnly: true).first)
        #expect(withSubject.subject == "zqxmarker budget")
        #expect(!"\(withSubject.subject) \(withSubject.senderName) \(withSubject.link)".contains("BODYMARKER"))
        #expect(try await f.intents.findConversations("zqxbatch", account: nil, limit: 0, importantOnly: false).count == 1)
        #expect(try await f.intents.findConversations("zqxbatch", account: nil, limit: 99, importantOnly: false).count == 20)
        #expect(try await f.intents.findConversations("zqxbatch", account: "1", limit: 20, importantOnly: false).isEmpty)
        #expect(await f.refusal { _ = try await f.intents.findConversations("  ", account: nil, limit: 5,
                                                                            importantOnly: false) } == .emptyQuery)
        #expect(f.recorder.calls.isEmpty, "no Gmail search, no fetch: local only")
    }

    @Test func entityIdsRoundTripAndResolveFromTheLocalCacheOnly() async throws {
        let f = IntentFixture()
        await f.loaded()
        let row = try #require(try await f.inbox(IntentFixture.personal).first)
        let id = f.id(row)
        #expect(SpotlightIdentifier.parse(id)?.account == row.id.account)
        #expect(SpotlightIdentifier.parse(id)?.thread == row.id.gmailThreadID)
        let found = try await f.intents.threads(for: [id, "oh.thread.2.not-on-this-mac", "garbage", "oh.thread.99.x"])
        #expect(found.map(\.id) == [id], "a conversation that is not local is left out")
        #expect(found.first?.accountName == "Personal")
        #expect(!f.recorder.calls.contains("fetchThreadNow"))
        let suggested = try await f.intents.suggestedThreads()
        #expect(suggested.count <= 10)
        #expect(suggested.allSatisfy { $0.isUnread && $0.isImportant && $0.subject.isEmpty })
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func navigationIntentsLandWhereTheirLinkSays() async throws {
        let f = IntentFixture()
        await f.loaded()
        try await f.intents.openMailbox(.starred, account: nil)
        #expect(f.router.location == .system(.starred))
        #expect(f.active.windowShows == 1, "Mail comes forward")
        try await f.intents.searchMail("budget", account: "2")
        #expect(f.router.activeAccountID == IntentFixture.personal)
        #expect(f.router.location == .search("budget"))
        try await f.intents.openMailbox(.important, account: "1")
        #expect(f.router.activeAccountID == IntentFixture.work)
        await eventually { f.router.active?.splitsLoaded == true }
        #expect(f.router.location == f.router.active?.firstTab)
        let row = try #require(try await f.inbox(IntentFixture.work).dropFirst(2).first)
        try await f.intents.openThread(f.id(row))
        await eventually { f.router.reader?.thread == row.id }
        try await f.intents.openReviewQueue(account: nil)
        #expect(f.router.location == .reviewQueue(nil))
        #expect(await f.refusal { try await f.intents.openThread("oh.thread.99.abc") } == .unknownAccount)
        #expect(await f.refusal { try await f.intents.openMailbox(.inbox, account: "99") } == .unknownAccount)
        #expect(f.writes.isEmpty, "links only navigate")
    }

    @Test func aMailboxWhoseModuleIsOffSaysSo() async throws {
        let f = IntentFixture(flags: FeatureFlags().with(.snooze, false))
        await f.loaded()
        let error = await f.refusal { try await f.intents.openMailbox(.snoozed, account: nil) }
        #expect(error == .moduleOff("Snoozed"))
        #expect(error?.message == "Snoozed isn't turned on in Mail.")
        #expect(f.router.location != .system(.snoozed))
    }

    @Test func newMessageIsALinkComposerWithoutBcc() async throws {
        let f = IntentFixture()
        await f.loaded()
        let smuggled = await f.refusal {
            try await f.intents.newMessage(account: nil, to: ["a@example.com&bcc=spy@evil.example"], subject: nil, body: nil)
        }
        #expect(smuggled == .refused("One of the recipients isn't an email address Mail can use."))
        #expect(f.env.compose.windowSession == nil)
        try await f.intents.newMessage(account: "1", to: ["a@example.com", " b@example.com "], subject: "Hi",
                                       body: "Text\u{7}")
        let session = try #require(f.env.compose.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["a@example.com", "b@example.com"])
        #expect(session.bcc.tokens.isEmpty)
        #expect(session.subject == "Hi")
        await session.settle()
        #expect(f.writes.isEmpty, "a new message is only pre-filled")
        let many = (0...50).map { "r\($0)@example.com" }
        #expect(await f.refusal { try await f.intents.newMessage(account: nil, to: many, subject: nil, body: nil) }
                == .refused("A new message from Shortcuts can have at most 50 recipients."))
    }

    @Test func withTheSwitchOffEveryIntentStops() async throws {
        let f = IntentFixture(enabled: false)
        await f.loaded()
        let row = try #require(try await f.inbox(IntentFixture.work).first)
        let errors: [IntentError?] = [
            await f.refusal { _ = try await f.intents.countUnread(account: nil, kind: .important) },
            await f.refusal { _ = try await f.intents.findConversations("budget", account: nil, limit: 5, importantOnly: false) },
            await f.refusal { try await f.intents.openMailbox(.inbox, account: nil) },
            await f.refusal { try await f.intents.openThread(f.id(row)) },
            await f.refusal { try await f.intents.searchMail("budget", account: nil) },
            await f.refusal { try await f.intents.newMessage(account: nil, to: [], subject: nil, body: nil) },
            await f.refusal { _ = try await f.intents.markDone([f.id(row)], confirm: f.confirm) },
            await f.refusal { _ = try await f.intents.threads(for: [f.id(row)]) },
            await f.refusal { _ = try await f.intents.accounts() },
        ]
        #expect(errors.allSatisfy { $0 == .turnedOff })
        #expect(IntentError.turnedOff.message == "Shortcuts are off in Mail. Turn them on in Settings › Platform features.")
        #expect(f.active.windowShows == 0 && f.asked.isEmpty && f.recorder.calls.isEmpty)
        f.preferences.isEnabled = true
        #expect(try await f.intents.countUnread(account: nil, kind: .inbox) >= 0)
    }

    @Test func beforeTheAccountsLoadAnIntentWaitsTenSecondsThenStops() async throws {
        let f = IntentFixture(startWindow: false)
        let error = await f.refusal { _ = try await f.intents.countUnread(account: nil, kind: .important) }
        #expect(error == .notReady)
        #expect(error?.message == "Mail is still starting. Try again in a moment.")
        #expect(f.clock.sleepCount >= 100, "10 s in 100 ms steps on the fake clock")
    }

    @Test func changesNeedTheirOwnOptIn() async throws {
        let f = IntentFixture(allowChanges: false)
        await f.loaded()
        let row = try #require(try await f.inbox(IntentFixture.work).first)
        #expect(await f.refusal { _ = try await f.intents.markDone([f.id(row)], confirm: f.confirm) } == .changesOff)
        #expect(f.asked.isEmpty && f.writes.isEmpty)
    }

    @Test func aDeclinedQuestionChangesNothing() async throws {
        let f = IntentFixture()
        await f.loaded()
        f.answer = false
        let rows = try await f.inbox(IntentFixture.work)
        #expect(await f.refusal { _ = try await f.intents.markDone(rows.prefix(2).map { f.id($0) }, confirm: f.confirm) }
                == .declined)
        #expect(f.asked == ["Mark 2 conversations done in Work?"], "counts and the account name only")
        #expect(f.writes.isEmpty)
    }

    @Test func anAllowedRunIsOneRegistryRunPerAccountWithUndoAndNoNavigation() async throws {
        let f = IntentFixture()
        await f.loaded()
        let work = try await f.inbox(IntentFixture.work, 20)
        let open = try #require(work.first { !$0.isUnread })
        let other = try #require(work.first { $0.id != open.id })
        let spare = try #require(work.first { $0.id != open.id && $0.id != other.id })
        let personal = try #require(try await f.inbox(IntentFixture.personal).first)
        f.router.open(open.id)
        await eventually { f.router.reader?.thread == open.id }
        let ids = [f.id(open), f.id(other), f.id(personal), f.id(open)]
        let message = try await f.intents.markDone(ids, confirm: f.confirm)
        #expect(message == "Marked 3 conversations done.")
        #expect(f.asked == ["Mark 2 conversations done in Work and 1 in Personal?"])
        #expect(f.recorder.calls.filter { $0 == "apply" }.count == 2, "one run per account")
        let titles = (f.env.undo?.stack ?? []).suffix(2).map { String(localized: $0.title) }
        #expect(titles == ["Marked 2 conversations done from Shortcuts", "Marked done from Shortcuts"])
        #expect(f.router.reader?.thread == open.id, "no done and next: the window does not move")
        #expect(f.router.activeAccountID == IntentFixture.work)
        #expect(await f.env.actions.run(.undo, source: .keyboard, host: f.router))
        #expect(f.recorder.calls.contains("undo"))
        f.preferences.askBeforeChanges = false
        f.asked = []
        _ = try await f.intents.markDone([f.id(spare)], confirm: f.confirm)
        #expect(f.asked.isEmpty)
    }

    @Test func snoozeAndRemindRunThroughTheirPickersCallbacks() async throws {
        let f = IntentFixture()
        await f.loaded()
        let rows = try await f.inbox(IntentFixture.work)
        let until = fixedNow.addingTimeInterval(2 * 86_400)
        let snoozed = try await f.intents.snooze(rows.prefix(2).map { f.id($0) }, until: until, confirm: f.confirm)
        #expect(snoozed.hasPrefix("Snoozed 2 conversations until "))
        #expect(f.asked.first?.hasPrefix("Snooze 2 conversations in Work until ") == true)
        #expect(f.env.undo?.stack.last.map { String(localized: $0.title) }?.hasSuffix("from Shortcuts") == true)
        let reminded = try await f.intents.remind(f.id(rows[3]), at: until, onlyIfNoReply: true, confirm: f.confirm)
        #expect(reminded.hasPrefix("Reminder set for ") && reminded.hasSuffix(" if no reply."))
        #expect(f.asked.last?.hasSuffix(" if nobody replies?") == true)
        #expect(await f.refusal { _ = try await f.intents.snooze([f.id(rows[4])], until: fixedNow.addingTimeInterval(-60),
                                                                 confirm: f.confirm) } == .pastDate)
    }

    @Test func aChangeWhoseModuleIsOffSaysSo() async throws {
        let f = IntentFixture(flags: FeatureFlags().with(.snooze, false).with(.reminders, false))
        await f.loaded()
        let row = try #require(try await f.inbox(IntentFixture.work).first)
        let until = fixedNow.addingTimeInterval(86_400)
        #expect(await f.refusal { _ = try await f.intents.snooze([f.id(row)], until: until, confirm: f.confirm) }
                == .moduleOff("Snooze"))
        #expect(await f.refusal { _ = try await f.intents.remind(f.id(row), at: until, onlyIfNoReply: false,
                                                                 confirm: f.confirm) } == .moduleOff("Remind me"))
        #expect(f.writes.isEmpty)
    }

    @Test func limitsRefuseWithZeroWrites() async throws {
        let f = IntentFixture()
        await f.loaded()
        let row = try #require(try await f.inbox(IntentFixture.work).first)
        let many = (0..<51).map { "oh.thread.1.t\($0)" }
        #expect(await f.refusal { _ = try await f.intents.markDone(many, confirm: f.confirm) } == .tooMany)
        #expect(await f.refusal { _ = try await f.intents.markDone([], confirm: f.confirm) } == .nothingGiven)
        #expect(await f.refusal { _ = try await f.intents.markDone(["oh.thread.99.x"], confirm: f.confirm) }
                == .unknownAccount)
        #expect(await f.refusal { _ = try await f.intents.markDone(["oh.thread.1.not-here"], confirm: f.confirm) }
                == .notLocal)
        f.clock.advance(11)
        f.answer = false
        for _ in 0..<5 {
            #expect(await f.refusal { _ = try await f.intents.markDone([f.id(row)], confirm: f.confirm) } == .declined)
        }
        #expect(await f.refusal { _ = try await f.intents.markDone([f.id(row)], confirm: f.confirm) } == .rateLimited)
        f.clock.advance(10)
        #expect(await f.refusal { _ = try await f.intents.markDone([f.id(row)], confirm: f.confirm) } == .declined)
        #expect(f.writes.isEmpty)
    }
}

@MainActor
@Suite struct IntentCatalogTests {
    @Test func everyIntentMapsToASafeExistingAction() {
        for info in IntentCatalog.all {
            for id in info.actions {
                let descriptor = ActionCatalog.descriptor(id)
                #expect(descriptor != nil, "\(info.name): \(id) is not in the catalog")
                #expect(descriptor?.effect != .external && descriptor?.isDestructive != true, "\(info.name): \(id)")
                #expect(!IntentCatalog.neverExposed.contains(id), "\(info.name): \(id)")
                #expect(descriptor?.effect == (info.tier == .write ? .mail : .view), "\(info.name): \(id)")
            }
            if let module = info.module {
                #expect(FeatureModuleID.mur1.contains(module) || FeatureModuleID.mur2.contains(module))
            }
        }
        #expect(IntentCatalog.all.count == 10)
        #expect(IntentCatalog.writeTitles == ["Mark done", "Snooze", "Remind me"])
        for id in IntentCatalog.neverExposed {
            #expect(ActionCatalog.descriptor(id) != nil, "\(id)")
        }
    }

    @Test func aSenderNameIsNeverAnAddress() {
        #expect(IntentEntityBuilder.senderName(nil) == IntentEntityBuilder.unknownSender)
        #expect(IntentEntityBuilder.senderName("  ") == IntentEntityBuilder.unknownSender)
        #expect(IntentEntityBuilder.senderName("dana@example.com") == IntentEntityBuilder.unknownSender)
        #expect(IntentEntityBuilder.senderName(" Dana Park ") == "Dana Park")
    }

    @Test func preferencesDefaultToOffExceptAsking() throws {
        let defaults = ScopedDefaults("dev.openhuman.mail.tests.intents")
        defer { defaults.cleanup() }
        let preferences = IntentPreferences(defaults: defaults)
        #expect(!preferences.isEnabled && !preferences.shareSubjects && !preferences.allowMailChanges)
        #expect(preferences.askBeforeChanges)
        #expect(IntentPreferences.enabledKey == "feature.appIntents.enabled")
        preferences.isEnabled = true
        #expect(FeatureFlags.load(from: defaults).isEnabled(.appIntents, default: false), "the launch flags read it too")
        #expect(!AppIntentsModule.defaultEnabled && FeatureModuleID.optIn.contains(.appIntents))
    }
}
