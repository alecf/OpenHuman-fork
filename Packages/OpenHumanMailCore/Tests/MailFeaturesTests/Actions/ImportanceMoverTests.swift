import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class HeldImportanceRules: ImportanceRulesPort, Sendable {
    let fake: FakeImportanceRules
    private let held = Mutex<Checkpoint?>(nil)

    init(_ fake: FakeImportanceRules) { self.fake = fake }

    func hold(_ checkpoint: Checkpoint) { held.withLock { $0 = checkpoint } }

    func apply(_ change: ImportanceChange) async throws -> UndoToken {
        let checkpoint = held.withLock { value -> Checkpoint? in
            defer { value = nil }
            return value
        }
        if let checkpoint { await checkpoint.pass() }
        return try await fake.apply(change)
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? { try await fake.undo(token) }
    func explain(_ thread: ThreadKey) async throws -> ImportanceExplanation { try await fake.explain(thread) }
    func rules(_ account: AccountID) -> AsyncThrowingStream<[ImportanceRuleInfo], Error> { fake.rules(account) }
}

@MainActor
final class MoverFixture {
    static let account = AccountID(1)
    static let important = GmailLabelID("IMPORTANT")
    static let sender = EmailAddress(name: "Nia Letters", email: "nia@letters.example")

    let store: FakeMailStore
    let commands: RecordingCommands
    let fake: FakeImportanceRules
    let rules: HeldImportanceRules
    let env: AppEnvironment
    let router: AppRouter?

    init(location: MailLocation? = nil) {
        let corpus = FakeCorpus.make(threadCount: 12, now: fixedNow)
        let store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, now: { fixedNow }))
        let commands = RecordingCommands(store)
        let fake = FakeImportanceRules(corpus: corpus, now: { fixedNow })
        fake.setGmailImportantLookup { [weak store] key in store?.isGmailImportant(key) }
        let rules = HeldImportanceRules(fake)
        let env = AppEnvironment(data: store, commands: commands, accounts: store, settings: store, isFake: true,
                                 notices: NoticeCenter(autoExpire: false), importance: rules, featureFlags: FeatureFlags())
        self.store = store
        self.commands = commands
        self.fake = fake
        self.rules = rules
        self.env = env
        if let location {
            let router = AppRouter(environment: env, location: location)
            router.start()
            self.router = router
        } else {
            router = nil
        }
    }

    func loadedList() async throws -> ThreadListModel {
        let router = try #require(router)
        await untilObserved { router.list?.state == .loaded && router.list?.rows.isEmpty == false }
        return try #require(router.list)
    }

    func conversation(_ subject: String, messages: Int = 2, important: Bool = true) async throws
        -> (thread: ThreadKey, messages: [MessageKey]) {
        var keys = [store.deliverMessage(account: Self.account, from: Self.sender, subject: subject, important: important)]
        let thread = try #require(try await inbox().first { $0.subject == subject }).id
        for n in 1..<max(1, messages) {
            keys.append(store.deliverMessage(account: Self.account, to: thread, from: Self.sender, subject: "Re: \(subject)",
                                             text: "Reply \(n).", important: important))
        }
        return (thread, keys)
    }

    func inbox() async throws -> [ThreadRow] {
        try await store.threadPage(.system(.inbox), account: Self.account, after: nil, limit: 500).rows
    }

    func context(_ thread: ThreadKey, location: MailLocation = .system(.inbox), sender: String? = nil) -> ActionContext {
        ActionContext(scope: .list, account: thread.account, accountCount: 1, location: location, selection: [thread],
                      focusedThread: thread, sender: sender, hasRows: true)
    }

    func perform(_ id: ActionID, _ context: ActionContext) async {
        let feedback = ActionFeedback(environment: env)
        let handler: any ActionHandler
        if ClassificationCorrectionHandler.ids.contains(id) {
            handler = ClassificationCorrectionHandler(environment: env, feedback: feedback)
        } else {
            handler = ImportanceActionHandler(environment: env, feedback: feedback)
        }
        if case .started(let task) = handler.perform(ActionRequest(id: id, context: context, source: .palette, host: nil)) {
            await task.value
        }
        withExtendedLifetime(handler) {}
    }

    func marked(_ message: MessageKey) -> Bool { store.serverLabels(of: message).contains(Self.important) }

    var labelWrites: [MailCommand] {
        commands.commands.filter { if case .modifyLabels = $0 { true } else { false } }
    }

    func pins(_ thread: ThreadKey) -> [ImportanceRuleInfo] {
        fake.allRules.filter { $0.match == .thread && $0.value == thread.gmailThreadID.rawValue }
    }

    var undo: UndoCoordinator { env.undo! }

    func title(_ entry: UndoCoordinator.Entry?) -> String? { entry.map { String(localized: $0.title) } }
}

@MainActor
@Suite struct ImportanceMoverTests {
    typealias F = MoverFixture

    @Test func movingToOtherPinsAndClearsGmailsMarkInOneUndoEntry() async throws {
        let f = F()
        let (thread, messages) = try await f.conversation("Quarterly plan", messages: 3)
        #expect(messages.allSatisfy(f.marked))

        await f.perform(.moveToOther, f.context(thread))
        #expect(f.pins(thread).map(\.effect) == [.neverImportant])
        #expect(!messages.contains(where: f.marked), "every visible message loses Gmail's mark")
        #expect(f.labelWrites == [.modifyLabels([thread], add: [], remove: [F.important])], "one write for the conversation")
        #expect(f.undo.stack.count == 1 && f.title(f.undo.stack.last) == "Moved to Other")

        await f.undo.undoLast()
        #expect(f.pins(thread).isEmpty)
        #expect(messages.allSatisfy(f.marked), "one ⌘Z puts the rule and the mark back")
        await f.undo.redoLast()
        #expect(f.pins(thread).map(\.effect) == [.neverImportant] && !messages.contains(where: f.marked))
    }

    @Test func movingToImportantPinsAndSetsGmailsMarkOnEveryMessage() async throws {
        let f = F()
        let (thread, messages) = try await f.conversation("Venue shortlist", messages: 2, important: false)
        #expect(!messages.contains(where: f.marked))

        await f.perform(.moveToImportant, f.context(thread))
        #expect(f.pins(thread).map(\.effect) == [.important])
        #expect(messages.allSatisfy(f.marked))
        #expect(f.labelWrites == [.modifyLabels([thread], add: [F.important], remove: [])])
        #expect(f.title(f.undo.stack.last) == "Moved to Important")
        await f.undo.undoLast()
        #expect(f.pins(thread).isEmpty && !messages.contains(where: f.marked))
    }

    @Test func markImportantAddsTheMarkToTheMessagesThatLackIt() async throws {
        let f = F()
        let (thread, first) = try await f.conversation("Budget review", messages: 1, important: true)
        let second = f.store.deliverMessage(account: F.account, to: thread, from: F.sender, subject: "Re: Budget review",
                                            important: false)
        #expect(f.marked(first[0]) && !f.marked(second))
        await f.perform(.classificationMarkImportant, f.context(thread))
        #expect(f.marked(first[0]) && f.marked(second), "the whole conversation, as in Gmail")
        #expect(f.undo.stack.count == 1)
    }

    @Test func withTheSwitchOffAMoveChangesOnlyThisMac() async throws {
        let f = F()
        try await f.store.set(AppSettings.importanceSendsToGmail, false)
        let (thread, messages) = try await f.conversation("Newsletter digest")
        await f.perform(.moveToOther, f.context(thread))
        await f.perform(.classificationMarkImportant, f.context(thread))
        #expect(f.labelWrites.isEmpty, "nothing is sent to Gmail")
        #expect(messages.allSatisfy(f.marked))
        #expect(f.pins(thread).map(\.effect) == [.important])
        #expect(f.undo.stack.map { String(localized: $0.title) }
            == ["Moved to Other on this Mac", "Moved to Important on this Mac"])
        await f.undo.undoLast()
        await f.undo.undoLast()
        #expect(f.pins(thread).isEmpty && f.labelWrites.isEmpty)
    }

    @Test func notImportantAndMoveToOtherBehaveTheSame() async throws {
        let f = F()
        let (a, aMessages) = try await f.conversation("Weekly offers")
        let (b, bMessages) = try await f.conversation("Monthly offers")
        await f.perform(.classificationNotImportant, f.context(a))
        await f.perform(.moveToOther, f.context(b))
        #expect(f.pins(a).map(\.effect) == [.neverImportant] && f.pins(b).map(\.effect) == [.neverImportant])
        #expect(!aMessages.contains(where: f.marked) && !bMessages.contains(where: f.marked))
        #expect(f.undo.stack.map { String(localized: $0.title) } == ["Moved to Other", "Moved to Other"])
        #expect(f.labelWrites == [.modifyLabels([a], add: [], remove: [F.important]),
                                  .modifyLabels([b], add: [], remove: [F.important])])
        let example = try #require(await f.env.classification.examples().first)
        #expect(example.expected == "not_important" && example.was == "important", "only the correction is an example")
        #expect(await f.env.classification.examples().count == 1)
    }

    @Test func anArchivedConversationGetsTheMarkButStaysArchived() async throws {
        let f = F()
        let (thread, messages) = try await f.conversation("Old receipt", messages: 1, important: false)
        _ = try await f.store.apply(.markDone([thread]))
        let writes = f.labelWrites.count
        await f.perform(.moveToImportant, f.context(thread, location: .system(.allMail)))
        #expect(f.title(f.undo.stack.last) == "Marked important")
        #expect(f.marked(messages[0]))
        #expect(Array(f.labelWrites.dropFirst(writes)) == [.modifyLabels([thread], add: [F.important], remove: [])])
        #expect(try await !f.inbox().contains { $0.id == thread }, "not moved back to the Inbox")
    }

    @Test func withoutAnImportantLabelRowThePinStaysAndTheNoticeSaysSo() async throws {
        let f = F()
        let (thread, messages) = try await f.conversation("Fresh account")
        f.store.failNextCommand(.notFound("label"))
        await f.perform(.moveToOther, f.context(thread))
        #expect(f.pins(thread).map(\.effect) == [.neverImportant], "the move is kept on this Mac")
        #expect(messages.allSatisfy(f.marked))
        #expect(f.env.notices.toasts.contains { $0.message == ImportanceMover.labelsNotSyncedText })
        #expect(f.undo.stack.count == 1)
        await f.undo.undoLast()
        #expect(f.pins(thread).isEmpty)
    }

    @Test func theFollowUpAfterAMoveSavesNothingUntilTapped() async throws {
        let f = F()
        let (thread, _) = try await f.conversation("Product update")
        await f.perform(.moveToOther, f.context(thread, sender: F.sender.email))
        let followUp = try #require(f.env.notices.toasts.first { $0.message == "Never important for:" })
        #expect(followUp.actionTitle == "This sender" && followUp.secondaryActionTitle == "This domain")
        #expect(f.fake.allRules.count == 1, "only the move")
        await f.env.notices.activate(followUp.id)
        #expect(f.fake.allRules.contains { $0.kind == .neverSender && $0.value == F.sender.email })
        #expect(f.undo.stack.count == 2, "the rule is its own undo entry")
    }

    @Test func theRowLeavesTheTabBeforeTheStoreAnswers() async throws {
        let f = F(location: .splitOther)
        let list = try await f.loadedList()
        let router = try #require(f.router)
        let key = try #require(list.rows.first { !$0.isImportant }?.id)
        list.setCursor(key)
        let writes = f.labelWrites.count
        let gate = Checkpoint()
        f.rules.hold(gate)
        let running = Task { await f.env.actions.run(.moveToImportant, source: .keyboard, host: router) }
        await gate.arrived()
        #expect(!list.rows.contains { $0.id == key }, "gone from Other while the rule is still being written")
        #expect(f.labelWrites.count == writes)
        gate.release()
        #expect(await running.value)
        #expect(Array(f.labelWrites.dropFirst(writes)) == [.modifyLabels([key], add: [F.important], remove: [])])
        #expect(f.store.isGmailImportant(key) == true)
        #expect(!list.rows.contains { $0.id == key })
    }

    @Test func aFailedLocalWriteUndoesThePinRevertsTheRowAndOffersRetry() async throws {
        let f = F(location: .splitOther)
        let list = try await f.loadedList()
        let router = try #require(f.router)
        let key = try #require(list.rows.first { !$0.isImportant }?.id)
        list.setCursor(key)
        f.store.failNextCommand(.unavailable("injected failure"))
        #expect(await f.env.actions.run(.moveToImportant, source: .keyboard, host: router))
        #expect(f.pins(key).isEmpty, "the pin is rolled back")
        #expect(f.undo.stack.isEmpty)
        #expect(f.store.isGmailImportant(key) == false)
        await untilObserved { list.rows.contains { $0.id == key } }
        let failure = try #require(f.env.notices.toasts.first { $0.message == ImportanceMover.failure(true) })
        #expect(failure.style == .error && failure.actionTitle == "Retry")

        await f.env.notices.activate(failure.id)
        #expect(f.pins(key).map(\.effect) == [.important])
        #expect(f.store.isGmailImportant(key) == true)
        #expect(f.undo.stack.count == 1 && f.title(f.undo.stack.last) == "Moved to Important")
    }

    @Test func theOptimisticStepMatchesWhereTheRowIs() {
        let key = ThreadKey(account: F.account, rowID: 1, gmailThreadID: GmailThreadID("t1"))
        func effect(_ location: MailLocation, toImportant: Bool, gmail: Bool, implies: Bool = false) -> OptimisticEffect {
            OptimisticEffect.importanceMove([key], toImportant: toImportant, changesGmail: gmail, in: location,
                                            impliesImportance: implies)
        }
        let important = MailLocation.split(SplitKey("important"))
        #expect(effect(important, toImportant: false, gmail: false, implies: true).hidden == [key])
        #expect(effect(.splitOther, toImportant: true, gmail: false).hidden == [key])
        #expect(effect(.system(.important), toImportant: false, gmail: true).hidden == [key])
        #expect(effect(.system(.important), toImportant: false, gmail: false).isEmpty, "Gmail's folder only follows its mark")
        #expect(effect(.splitOther, toImportant: false, gmail: true).patches[key]
            == RowPatch(isImportant: false, isPlacedImportant: false))
        #expect(effect(.system(.allMail), toImportant: true, gmail: true).patches[key] == RowPatch(isImportant: true))
        #expect(effect(.search("plan"), toImportant: true, gmail: false).isEmpty)
        let row = ThreadRow(id: key, subject: "Plan", snippet: "", participantsDisplay: "Nia", participants: [],
                            messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                            isStarred: false, isImportant: true, userLabelIDs: [], lastMessageAt: fixedNow, sortAt: fixedNow,
                            isPlacedImportant: true)
        let patch = RowPatch(isImportant: false, isPlacedImportant: false)
        let moved = patch.applied(to: row)
        #expect(!moved.isImportant && !moved.isPlacedImportant && patch.isReflected(in: moved) && !patch.isReflected(in: row))
    }
}
