import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let account = AccountID(1)

private func label(_ id: Int64, _ name: String) -> LabelInfo {
    LabelInfo(id: id, account: account, labelID: GmailLabelID("Label_\(id)"), kind: .user, name: name,
              displayName: String(name.split(separator: "/").last ?? Substring(name)), position: Int(id))
}

private func split(_ id: String, _ name: String, _ rule: String, position: Int) -> SplitInfo {
    SplitInfo(id: SplitKey(id), account: account, name: name, position: position, ruleText: rule)
}

private let alpha = label(1, "Alpha")
private let clients = label(2, "Clients")
private let atlas = label(3, "Projects/Atlas")
private let receipts = label(4, "Receipts")
private let travel = label(5, "Travel")
private let labels = [travel, clients, alpha, receipts, atlas]

private let importantSplit = split("s0", "Important", "is:important", position: 0)
private let clientTab = split("s1", "Client tab", "label:\"Clients\"", position: 1)
private let newsletters = split("s2", "Newsletters", "category:promotions OR category:updates", position: 2)
private let calendar = split("s3", "Calendar", "is:event", position: 3)
private let splits = [importantSplit, clientTab, newsletters, calendar]

private let key = ThreadKey(account: account, rowID: 1, gmailThreadID: GmailThreadID("t1"))
private let sender = SplitRuleChoice(kind: .sender, value: "dana@example.com")
private let allPlaces = [MovePlaceOption(place: .inbox), MovePlaceOption(place: .important), MovePlaceOption(place: .other)]

@MainActor
private final class PickerRecorder {
    var calls: [String] = []

    var actions: LabelPickerActions {
        LabelPickerActions(
            setLabels: { add, remove in self.calls.append("setLabels:\(add.map(\.name)):\(remove.map(\.name))") },
            move: { self.calls.append("move:\($0.name)") },
            create: { self.calls.append("create:\($0)") },
            navigate: { self.calls.append("navigate:\($0.name)") },
            moveToPlace: { self.calls.append("place:\($0.rawValue)") },
            moveToSplit: { split, label in self.calls.append("split:\(split.name):\(label.name)") },
            addSenderToSplit: { split, choice in self.calls.append("addSender:\(split.name):\(choice.value)") })
    }
}

@MainActor
private func picker(_ recorder: PickerRecorder, move: MoveOptions? = MoveOptions(places: allPlaces, splits: splits,
                                                                                  sender: sender),
                    mode: LabelPickerMode = .move, account: AccountID? = account) -> LabelPickerModel {
    LabelPickerModel(mode: mode, targets: [key], account: account, labels: labels, targetRows: [],
                     actions: recorder.actions, move: move)
}

@MainActor
@Suite struct MoveToSupersetPickerTests {
    @Test func placesThenSplitsThenLabelsUnderTheirHeaders() {
        let model = picker(PickerRecorder())
        #expect(model.rows.map(\.title) == ["Inbox", "Important", "Other",
                                            "Client tab", "Newsletters", "Add this sender to Newsletters", "Calendar",
                                            "Alpha", "Atlas", "Receipts", "Travel"])
        #expect(model.rows.map(\.section) == [.places, .places, .places, .splits, .splits, .splits, .splits,
                                              .labels, .labels, .labels, .labels])
        let headers = model.rows.indices.compactMap { index in model.header(before: index).map { "\(index):\($0)" } }
        #expect(headers == ["0:Places", "3:Splits", "7:Labels"])
        #expect(model.cursor == 0, "the cursor starts on the first row that can be chosen")
        #expect(!model.rows.contains { if case .split(let s, _) = $0.kind { s.id == importantSplit.id } else { false } },
                "the importance split is the Important place, not a split row")
        #expect(model.rows.allSatisfy { $0.check == nil }, "no checkboxes in Move to")
    }

    @Test func emptyQueryPutsRecentlyUsedLabelsFirstThenAlphabetical() {
        let recent = MoveOptions(places: [], splits: [], recentLabelIDs: [travel.id, receipts.id, 999])
        let model = picker(PickerRecorder(), move: recent)
        let names = model.rows.compactMap { if case .label(let l) = $0.kind { l.name } else { nil } }
        #expect(names == ["Travel", "Receipts", "Alpha", "Clients", "Projects/Atlas"])
        model.query = "a"
        let typed = model.rows.compactMap { if case .label(let l) = $0.kind { l.name } else { nil } }
        #expect(typed.first == "Alpha", "a typed query ranks by match, not recency")
        #expect(MoveToSuperset.noting(alpha.id, in: [travel.id, alpha.id]) == [alpha.id, travel.id])
        #expect(MoveToSuperset.noting(9, in: [1, 2, 3, 4, 5]) == [9, 1, 2, 3, 4], "at most five")
    }

    @Test func aLabelOnlySplitResolvesToItsLabel() {
        for rule in ["label:\"Clients\"", "label:Clients", "(label:Clients)", " LABEL:clients ", "label:\"Clients\" "] {
            #expect(MoveToSuperset.labelName(ofRule: rule)?.lowercased() == "clients", "\(rule)")
        }
        for rule in ["label:Clients OR from:dana@example.com", "-label:Clients", "from:@example.com", "label:",
                     "label:Clients label:Travel", "is:important", ""] {
            #expect(MoveToSuperset.labelName(ofRule: rule) == nil, "\(rule)")
        }
        #expect(MoveToSuperset.label(for: clientTab, in: labels) == clients)
        #expect(MoveToSuperset.label(for: split("x", "By id", "label:label_2", position: 9), in: labels) == clients,
                "a Gmail label id works too, case-insensitive")
        #expect(MoveToSuperset.label(for: split("y", "Gone", "label:Archive2019", position: 9), in: labels) == nil)

        let model = picker(PickerRecorder())
        let row = model.rows.first { $0.title == "Client tab" }
        #expect(row?.kind == .split(clientTab, label: clients) && row?.isEnabled == true && row?.tag == "split")
    }

    @Test func aRuleSplitIsShownWithItsReasonAndNeverChosen() {
        let recorder = PickerRecorder()
        let model = picker(recorder, account: nil)
        let news = model.rows.first { $0.title == "Newsletters" }
        #expect(news?.disabledReason == "This split is made by a rule, not a label" && news?.isEnabled == false)
        #expect(model.rows.first { $0.title == "Calendar" }?.isEnabled == false)
        #expect(!model.rows.contains { $0.title == "Add this sender to Calendar" }, "never into an events-only split")

        model.query = "calendar"
        #expect(model.rows.map(\.title) == ["Calendar"])
        model.confirm()
        model.choose(model.rows[0])
        #expect(recorder.calls.isEmpty && !model.isClosed, "↵ and a click do nothing on a row that cannot be chosen")

        model.query = "newsletters"
        #expect(model.rows.map(\.title) == ["Newsletters", "Add this sender to Newsletters"])
        #expect(model.cursor == 1, "the cursor starts on the first row that can be chosen")
        model.moveCursor(by: 1)
        #expect(model.cursor == 1, "↓ passes over the rule split")
        model.query = ""
        var visited: Set<Int> = []
        for _ in model.rows.indices {
            model.moveCursor(by: 1)
            visited.insert(model.cursor)
        }
        #expect(visited.allSatisfy { model.rows[$0].isEnabled })
        #expect(visited.count == model.rows.filter(\.isEnabled).count, "every row that can be chosen is reached")
    }

    @Test func aSplitThatIsAlsoALabelShowsOnce() {
        let model = picker(PickerRecorder())
        #expect(!model.rows.contains { $0.kind == .label(clients) }, "the split row wins over its label")
        model.query = "clients"
        #expect(model.rows.first?.title == "Client tab", "typing the label's name finds the split")
        #expect(!model.rows.contains { if case .create = $0.kind { true } else { false } }, "the label exists")

        let noSplits = picker(PickerRecorder(), move: MoveOptions(places: allPlaces))
        #expect(noSplits.rows.contains { $0.kind == .label(clients) }, "without the split the label is listed")
    }

    @Test func theCreateRowComesOnlyWithoutAnExactLabel() {
        let model = picker(PickerRecorder())
        model.query = "Receipts"
        #expect(!model.rows.contains { if case .create = $0.kind { true } else { false } })
        model.query = "Receipt"
        let last = model.rows.last
        #expect(last?.title == "Create label “Receipt”" && last?.section == .labels)
        model.query = "Client tab"
        #expect(model.rows.last?.title == "Create label “Client tab”", "a split's name is not a label: as today")
    }

    @Test func returnOnEachKindRunsExactlyOneAction() {
        let cases: [(query: String, call: String)] = [
            ("other", "place:other"),
            ("important", "place:important"),
            ("inbox", "place:inbox"),
            ("client tab", "split:Client tab:Clients"),
            ("newsletters", "addSender:Newsletters:dana@example.com"),
            ("travel", "move:Travel"),
            ("Brand New", "create:Brand New"),
        ]
        for (query, call) in cases {
            let recorder = PickerRecorder()
            let model = picker(recorder)
            model.query = query
            model.confirm()
            #expect(recorder.calls == [call], "\(query)")
            #expect(model.isClosed, "\(query)")
            model.confirm()
            #expect(recorder.calls.count == 1, "a closed picker does nothing more")
        }
    }

    @Test func theSwitchOffGivesTheLabelsOnlyPicker() {
        let model = picker(PickerRecorder(), move: nil)
        #expect(model.rows.map(\.title) == ["Alpha", "Clients", "Atlas", "Receipts", "Travel"])
        #expect(model.rows.allSatisfy { $0.section == nil && $0.isEnabled && $0.tag == nil })
        #expect(model.rows.indices.allSatisfy { model.header(before: $0) == nil }, "no headers")
        let labelMode = picker(PickerRecorder(), mode: .label)
        #expect(labelMode.move == nil && labelMode.rows.count == labels.count, "L never lists places or splits")
    }

    @Test func placesFollowEachActionsAvailability() {
        let all: (ActionID) -> ActionAvailability = { _ in .enabled }
        #expect(MoveToSuperset.places(targets: [key], availability: all).map(\.place) == [.inbox, .important, .other])
        let inInbox = MoveToSuperset.places(targets: [key]) { $0 == .moveToInbox ? .hidden : .enabled }
        #expect(inInbox.map(\.place) == [.important, .other], "Inbox only when the conversation is out of it")
        let other = ThreadKey(account: account, rowID: 2, gmailThreadID: GmailThreadID("t2"))
        let two = MoveToSuperset.places(targets: [key, other], availability: all)
        #expect(two.map(\.disabledReason) == [nil, MoveToSuperset.oneConversationReason, MoveToSuperset.oneConversationReason])
        let readOnly = MoveToSuperset.places(targets: [key]) { _ in .disabled(.safeMode) }
        #expect(readOnly.allSatisfy { $0.disabledReason == nil }, "read-only: offered, and refused out loud when chosen")
        let noPort = MoveToSuperset.places(targets: [key]) { $0 == .moveToInbox ? .disabled(.unavailable("Move to Inbox")) : .hidden }
        #expect(noPort == [MovePlaceOption(place: .inbox, disabledReason: "Move to Inbox isn't available here")])
    }

    @Test func addThisSenderOnlyWhereTheRuleCanTakeItSafely() {
        #expect(AddToSplit.canAddSafely(to: newsletters))
        #expect(AddToSplit.canAddSafely(to: split("a", "Acme", "from:@example.com", position: 5)))
        #expect(!AddToSplit.canAddSafely(to: importantSplit))
        #expect(!AddToSplit.canAddSafely(to: calendar))
        #expect(!AddToSplit.canAddSafely(to: split("b", "Invites", "has:invite", position: 5)))
        #expect(!AddToSplit.canAddSafely(to: split("c", "Events", "is:event OR has:invite", position: 5)))
        #expect(!AddToSplit.canAddSafely(to: split("d", "Broken", "from:(", position: 5)), "a rule this app cannot read")
        #expect(AddToSplit.targets(splits).map(\.name) == ["Client tab", "Newsletters", "Calendar"],
                "Add to split… keeps offering the same splits")
        let noSender = picker(PickerRecorder(), move: MoveOptions(places: [], splits: splits, sender: nil))
        #expect(!noSender.rows.contains { if case .addSender = $0.kind { true } else { false } })
    }

    @Test func theCatalogFindsMoveToByItsNewWordsAndTheSettingIsOnByDefault() throws {
        let descriptor = try #require(ActionCatalog.descriptor(.move))
        for word in ["split", "important", "other", "inbox"] { #expect(descriptor.paletteKeywords.contains(word), "\(word)") }
        #expect(descriptor.defaultBindings == [.key("v")] && descriptor.changesMail)
        #expect(AppSettings.moveToSuperset.name == "ui.move_to_superset" && AppSettings.moveToSuperset.defaultValue)
    }
}

@MainActor
private final class PostedNotices {
    var messages: [String] = []

    init(_ notices: NoticeCenter) {
        notices.onPost = { [weak self] toast in self?.messages.append(toast.message) }
    }
}

@MainActor
@Suite struct MoveToSupersetHandlerTests {
    let corpus = FakeCorpus.rich(threadCount: 40, now: fixedNow)

    private func make(readOnly: Bool = false) -> (AppEnvironment, FakeMailStore, RecordingCommands, PostedNotices) {
        let options = FakeMailStore.Options(remoteAck: .immediate, safeMode: readOnly ? .readOnly : .normal,
                                            now: { fixedNow })
        let store = FakeMailStore(corpus: corpus, options: options)
        let recorder = RecordingCommands(store)
        let rules = FakeImportanceRules(corpus: corpus, safeMode: options.safeMode, now: { fixedNow })
        let env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: true,
                                 importance: rules, featureFlags: FeatureFlags())
        return (env, store, recorder, PostedNotices(env.notices))
    }

    private var mailbox: FakeCorpus.Mailbox { corpus.mailboxes[0] }
    private var inbox: GmailLabelID { GmailLabelID("INBOX") }
    private var inboxName: String { mailbox.labels.first { $0.labelID == inbox }?.name ?? "INBOX" }

    private func clientsLabel() throws -> LabelInfo {
        try #require(mailbox.labels.first { $0.kind == .user && $0.name == "Clients" })
    }

    private func inboxThread(without label: LabelInfo) throws -> ThreadKey {
        try #require(mailbox.threads.first { thread in
            thread.labels.values.contains { $0.contains(inbox) }
                && !thread.labels.values.contains { $0.contains(label.labelID) }
                && !thread.labels.values.contains { $0.contains(GmailLabelID("TRASH")) || $0.contains(GmailLabelID("SPAM")) }
        }?.row.id)
    }

    private func context(_ target: ThreadKey, location: MailLocation, env: AppEnvironment) -> ActionContext {
        ActionContext(scope: .list, account: target.account, accountCount: 1, location: location, selection: [target],
                      focusedThread: target, hasRows: true, safeMode: env.status.safeMode)
    }

    @Test func aLabelSplitIsOneModifyLabelsWithOneUndoThatPutsInboxBack() async throws {
        let (env, store, recorder, posted) = make()
        let handler = try #require(env.actions.threadActions)
        let clients = try clientsLabel()
        let target = try inboxThread(without: clients)
        let tab = SplitInfo(id: SplitKey("tab"), account: target.account, name: "Client tab", position: 1,
                            ruleText: "label:\"Clients\"")
        await handler.moveToSplit([target], split: tab, label: clients, host: nil)?.value
        #expect(recorder.calls == ["apply"], "one write, the same call a label move makes: no new Gmail call type")
        #expect(store.labelNames(of: target).contains("Clients") && !store.labelNames(of: target).contains(inboxName))
        #expect(env.undo?.stack.count == 1)
        #expect(posted.messages.contains("Moved to Client tab"))

        await env.undo?.undoLast()
        #expect(!store.labelNames(of: target).contains("Clients") && store.labelNames(of: target).contains(inboxName),
                "one undo restores the labels and INBOX")
        #expect(env.undo?.stack.isEmpty == true)
    }

    @Test func importantAndOtherAreTheExistingOneConversationMoves() async throws {
        let (env, _, _, posted) = make()
        let handler = try #require(env.actions.threadActions)
        let target = try inboxThread(without: try clientsLabel())
        let rules = try #require(env.importance as? FakeImportanceRules)
        let here = context(target, location: .system(.inbox), env: env)
        #expect(env.actions.availability(.moveToInbox, host: nil, context: here) == .hidden,
                "in the Inbox there is no Inbox place")

        await handler.moveToPlace(.other, context: here, host: nil)?.value
        #expect(rules.allRules.map(\.kind) == [.neverThread])
        #expect(posted.messages.contains("Moved to Other"))
        await handler.moveToPlace(.important, context: here, host: nil)?.value
        #expect(rules.allRules.map(\.kind) == [.alwaysThread])
        #expect(posted.messages.contains("Moved to Important"))
        #expect(env.undo?.stack.count == 2, "one undo entry each")
        await env.undo?.undoLast()
        #expect(rules.allRules.map(\.kind) == [.neverThread])
        await env.undo?.undoLast()
        #expect(rules.allRules.isEmpty)
    }

    @Test func inboxMovesAConversationBackFromALabel() async throws {
        let (env, store, _, posted) = make()
        let handler = try #require(env.actions.threadActions)
        let clients = try clientsLabel()
        let target = try #require(mailbox.threads.first { thread in
            thread.labels.values.contains { $0.contains(clients.labelID) } && !thread.labels.values.contains { $0.contains(inbox) }
        }?.row.id)
        let here = context(target, location: .label(clients.labelID), env: env)
        #expect(env.actions.availability(.moveToInbox, host: nil, context: here) == .enabled)
        await handler.moveToPlace(.inbox, context: here, host: nil)?.value
        #expect(store.labelNames(of: target).contains(inboxName))
        #expect(posted.messages.contains("Moved to Inbox"))
        await env.undo?.undoLast()
        #expect(!store.labelNames(of: target).contains(inboxName))
    }

    @Test func readOnlyRefusesEveryKindWithTheBlockedNotice() async throws {
        let (env, store, recorder, posted) = make(readOnly: true)
        let handler = try #require(env.actions.threadActions)
        let clients = try clientsLabel()
        let target = try inboxThread(without: clients)
        let tab = SplitInfo(id: SplitKey("tab"), account: target.account, name: "Client tab", position: 1,
                            ruleText: "label:\"Clients\"")
        #expect(handler.moveToSplit([target], split: tab, label: clients, host: nil) == nil)
        #expect(posted.messages.contains(StatusModel.blockedText))
        #expect(handler.moveToPlace(.other, context: context(target, location: .system(.inbox), env: env), host: nil) == nil)
        #expect((env.importance as? FakeImportanceRules)?.allRules.isEmpty == true)
        #expect(recorder.calls.isEmpty, "nothing reached the write port")
        #expect(!store.labelNames(of: target).contains("Clients"))
        #expect(env.undo?.stack.isEmpty == true)
    }
}
