import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailUI
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Synchronization
import Testing
@testable import OpenHumanMail

private final class RecordingEngine: MailEngineWriting {
    private let log = Mutex<[String]>([])
    var calls: [String] { log.withLock { $0 } }
    private func record(_ name: String) { log.withLock { $0.append(name) } }

    static let receipt = ActionReceipt(operationIDs: [])
    static let sendReceipt = SendReceipt(draftID: DraftID("d1"), sendOperationID: OperationID(rawValue: 1), sendAfter: Date())

    func perform(_ action: MailAction, origin: OperationOrigin) async throws -> ActionReceipt { record("perform"); return Self.receipt }
    func undo(_ receipt: ActionReceipt) async throws -> ActionReceipt? { record("undo"); return nil }
    func createLabel(account: AccountID, name: String, applyTo: [ThreadRef]) async throws -> ActionReceipt {
        record("createLabel"); return Self.receipt
    }
    func newDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?, origin: DraftOrigin,
                  initial: DraftContent?) async throws -> NewDraft {
        record("newDraft"); return NewDraft(id: DraftID("d1"), version: 1)
    }
    func saveDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) async throws -> Int { record("saveDraft"); return 2 }
    func flushDraft(_ id: DraftID) async throws { record("flushDraft") }
    func discardDraft(_ id: DraftID) async throws { record("discardDraft") }
    func setReviewState(_ id: DraftID, _ state: DraftReviewState) async throws { record("setReviewState") }
    func resolveDraftConflict(_ id: DraftID, keep: DraftConflictChoice) async throws { record("resolveDraftConflict") }
    func send(_ id: DraftID, authorization: SendAuthorization, undoWindow: Duration?) async throws -> SendReceipt {
        record("send"); return Self.sendReceipt
    }
    func cancelSend(_ receipt: SendReceipt) async throws -> Bool { record("cancelSend"); return true }
    func sendNow(_ receipt: SendReceipt) async throws -> Bool { record("sendNow"); return true }
    func scheduleSend(_ id: DraftID, at: Date) async throws { record("scheduleSend") }
    func cancelScheduledSend(_ id: DraftID) async throws { record("cancelScheduledSend") }
    func fetchDraft(account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftID? { record("fetchDraft"); return nil }
    func fetchThread(account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRef? {
        record("fetchThread"); return nil
    }
    func upsertSnippet(_ snippet: SnippetItem) async throws -> SnippetItem { record("upsertSnippet"); return snippet }
    func deleteSnippet(id: String) async throws { record("deleteSnippet") }
    func recordSnippetUse(id: String) async throws { record("recordSnippetUse") }
    func storeSnippetAttachment(file: URL, mimeType: String) async throws -> SnippetAttachment {
        record("storeSnippetAttachment")
        return SnippetAttachment(contentHash: String(repeating: "0", count: 64), filename: "x.txt", mimeType: mimeType, size: 1)
    }
    func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachment {
        record("storeSnippetAttachment")
        return SnippetAttachment(contentHash: String(repeating: "0", count: 64), filename: filename, mimeType: mimeType, size: data.count)
    }
    func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?,
                     enabled: Bool) async throws -> SplitID {
        record("upsertSplit"); return SplitID("s1")
    }
    func deleteSplit(_ id: SplitID) async throws { record("deleteSplit") }
    func reorderSplits(account: AccountID, _ ids: [SplitID]) async throws { record("reorderSplits") }
    func dismissFailedOperation(_ id: OperationID) async throws { record("dismissFailedOperation") }
}

private let account = AccountID(1)
private let thread = ThreadKey(account: account, rowID: 1, gmailThreadID: GmailThreadID("t1"))
private let message = MessageKey(account: account, rowID: 1, gmailMessageID: GmailMessageID("m1"))
private let draft = DraftKey("d1")
private let sendToken = SendToken(draft: draft, sendAfter: Date(),
                                  payload: try! JSONEncoder().encode(RecordingEngine.sendReceipt))
private let undoToken = UndoToken(payload: try! JSONEncoder().encode(RecordingEngine.receipt))

private let portCalls: [(name: String, call: @Sendable (any MailCommanding) async throws -> Void)] = [
    ("apply", { _ = try await $0.apply(.markDone([thread])) }),
    ("undo", { _ = try await $0.undo(undoToken) }),
    ("createDraft", { _ = try await $0.createDraft(DraftInput(account: account, mode: .new)) }),
    ("updateDraft", { _ = try await $0.updateDraft(draft, DraftFields(subject: "x"), expectedVersion: 1) }),
    ("flushDraft", { try await $0.flushDraft(draft) }),
    ("discardDraft", { try await $0.discardDraft(draft) }),
    ("setReviewState", { try await $0.setReviewState(draft, .approved) }),
    ("resolveDraftConflict", { try await $0.resolveDraftConflict(draft, .keepLocal) }),
    ("send", { _ = try await $0.send(draft, undoWindow: .seconds(10)) }),
    ("cancelSend", { _ = try await $0.cancelSend(sendToken) }),
    ("sendNow", { _ = try await $0.sendNow(sendToken) }),
    ("scheduleSend", { try await $0.scheduleSend(draft, at: Date().addingTimeInterval(3_600)) }),
    ("cancelScheduledSend", { try await $0.cancelScheduledSend(draft) }),
    ("fetchDraftNow", { _ = try await $0.fetchDraftNow(account, gmailDraftID: GmailDraftID("r1")) }),
    ("fetchThreadNow", { _ = try await $0.fetchThreadNow(account, gmailThreadID: GmailThreadID("t1")) }),
    ("createLabel", { _ = try await $0.createLabel(account, name: "Synthetic", applyTo: [thread]) }),
    ("upsertSnippet", { _ = try await $0.upsertSnippet(SnippetInfo(name: "x", bodyHTML: "<p>x</p>")) }),
    ("deleteSnippet", { try await $0.deleteSnippet("s1") }),
    ("recordSnippetUse", { try await $0.recordSnippetUse("s1") }),
    ("storeSnippetAttachment", { _ = try await $0.storeSnippetAttachment(URL(fileURLWithPath: "/dev/null"), mimeType: "text/plain") }),
    ("storeSnippetAttachment", { _ = try await $0.storeSnippetAttachment(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain") }),
    ("unsubscribe", { try await $0.unsubscribe(message) }),
    ("upsertSplit", { _ = try await $0.upsertSplit(SplitDefinition(account: account, name: "x", ruleText: "is:starred")) }),
    ("deleteSplit", { try await $0.deleteSplit(account, SplitKey("s1")) }),
    ("reorderSplits", { try await $0.reorderSplits(account, [SplitKey("s1")]) }),
    ("dismissFailedOperation", { try await $0.dismissFailedOperation(1) }),
]

private let readThroughs: Set<String> = ["fetchDraftNow", "fetchThreadNow"]
private let sends: Set<String> = ["send", "sendNow", "scheduleSend", "unsubscribe"]

private func outcome(_ call: @Sendable (any MailCommanding) async throws -> Void,
                     on port: any MailCommanding) async -> MailPortError? {
    do {
        try await call(port)
        return nil
    } catch let error as MailPortError {
        return error
    } catch {
        return .unavailable("unexpected \(type(of: error))")
    }
}

@Test func theWritePortRefusesEveryWriteInReadOnlyBeforeTheEngineIsReached() async {
    let engine = RecordingEngine()
    let lookups = Mutex(0)
    let oneClicks = Mutex(0)
    let port = MailStoreCommands(engine: { lookups.withLock { $0 += 1 }; return engine }, safeMode: .readOnly,
                                 oneClick: { _ in oneClicks.withLock { $0 += 1 } })
    for (name, call) in portCalls where !readThroughs.contains(name) {
        #expect(await outcome(call, on: port) == .blockedBySafeMode, "\(name)")
    }
    #expect(engine.calls.isEmpty, "nothing reached the engine (or the Store behind it)")
    #expect(lookups.withLock { $0 } == 0, "the engine was not even looked up")
    #expect(oneClicks.withLock { $0 } == 0, "no unsubscribe request was made")
    for (name, call) in portCalls where readThroughs.contains(name) {
        #expect(await outcome(call, on: port) == nil, "\(name)")
    }
    #expect(engine.calls == ["fetchDraft", "fetchThread"])
    #expect(MailPortError.blockedBySafeMode.description == "Read-only: Mail can't change your mail")
}

@Test func theWritePortNeverSendsOutsideNormalMode() async {
    let engine = RecordingEngine()
    let oneClicks = Mutex(0)
    let port = MailStoreCommands(engine: { engine }, safeMode: .writeAllowlist,
                                 oneClick: { _ in oneClicks.withLock { $0 += 1 } })
    for (name, call) in portCalls {
        let result = await outcome(call, on: port)
        #expect(sends.contains(name) ? result == .blockedBySafeMode : result == nil, "\(name)")
    }
    #expect(Set(engine.calls).isDisjoint(with: ["send", "sendNow", "scheduleSend"]))
    #expect(oneClicks.withLock { $0 } == 0, "no unsubscribe request outside normal")

    let normalEngine = RecordingEngine()
    let normal = MailStoreCommands(engine: { normalEngine }, safeMode: .normal, oneClick: { _ in oneClicks.withLock { $0 += 1 } })
    for (name, call) in portCalls {
        #expect(await outcome(call, on: normal) == nil, "\(name)")
    }
    #expect(normalEngine.calls.contains("send") && normalEngine.calls.contains("perform"))
    #expect(oneClicks.withLock { $0 } == 1)
    let withoutRequest = MailStoreCommands(engine: { normalEngine }, safeMode: .normal)
    #expect(await outcome({ try await $0.unsubscribe(message) }, on: withoutRequest) == .unsupported("one-click unsubscribe"))
}

@Test func theWritePortTakesAChangeOfAnySizeInNormalMode() async {
    let many = (1...500).map { ThreadKey(account: account, rowID: Int64($0), gmailThreadID: GmailThreadID("t\($0)")) }
    let engine = RecordingEngine()
    let port = MailStoreCommands(engine: { engine }, safeMode: .normal)
    #expect(await outcome({ _ = try await $0.apply(.star(many)) }, on: port) == nil)
    #expect(await outcome({ _ = try await $0.createLabel(account, name: "Synthetic", applyTo: many) }, on: port) == nil)
    for (name, call) in portCalls where ["send", "sendNow", "scheduleSend"].contains(name) {
        #expect(await outcome(call, on: port) == nil, "\(name)")
    }
    #expect(engine.calls == ["perform", "createLabel", "send", "sendNow", "scheduleSend"])
}

@MainActor
@Test(.timeLimit(.minutes(2))) func aRealAccountSessionRefusesEveryWriteAtEveryLayer() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: Date())
    let gmail = FakeGmail(accountEmail: corpus.account.email)
    await FakeGmailLaunch.seed(gmail, corpus: corpus)
    let google = FakeGoogle(gmail: gmail)
    let email = corpus.account.email
    let store = try MailStore.openInMemoryForTesting()
    _ = try store.addAccount(email: email, displayName: nil, scopes: [GmailScope.readonly])
    let tokens = InMemoryTokenStore([email: StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.readonly],
                                                        clientID: SyntheticClient.clientID)])
    let backend = liveBackend(google: google, store: store, tokens: tokens, browser: RecordingBrowser(),
                              clientPath: try SyntheticClient.writeJSON())
    #expect(backend.safeMode == .readOnly)
    let app = AppModel(live: backend)
    guard case .mail(let environment) = app.screen, let session = app.session else {
        Issue.record("expected the mail window")
        return
    }
    defer { Task { await session.stop() } }
    _ = try await firstValue(environment.data.threadWindow(.system(.inbox), account: session.account, limit: 20)) {
        $0.rows.count == 5
    }
    let ref = try #require(try store.threadPage(view: .system(session.account, .inbox), after: nil, limit: 1).items.first?.ref)
    let snippetsBefore = try store.snippets(account: nil)
    let splitsBefore = try store.splits(account: session.account)

    #expect(session.safeMode == .readOnly && environment.status.safeMode == .readOnly)
    let port = try #require(environment.commands)
    for (name, call) in portCalls where !readThroughs.contains(name) {
        #expect(await outcome(call, on: port) == .blockedBySafeMode, "\(name)")
    }
    let key = MailStoreAdapter.threadKey(ref)
    await #expect(throws: MailPortError.blockedBySafeMode) { _ = try await port.apply(.markDone([key])) }
    #expect(try store.operations(account: session.account, statuses: [], limit: 50).isEmpty, "no op was queued")
    #expect(try store.drafts(account: nil, states: [], limit: 50).isEmpty, "no draft was created")
    #expect(try store.snippets(account: nil) == snippetsBefore && store.splits(account: session.account) == splitsBefore)

    await #expect(throws: EngineError.self) { _ = try await session.engine.perform(.archive([ref]), origin: .app) }
    await #expect(throws: EngineError.self) {
        _ = try await session.engine.newDraft(account: session.account, mode: .new, replyTo: nil, origin: .user)
    }
    #expect(try store.operations(account: session.account, statuses: [], limit: 50).isEmpty)

    let wire = google.api.requests.count
    await #expect(throws: GmailError.self) {
        try await session.api.batchModifyMessages(ids: ["m1"], add: [], remove: ["INBOX"])
    }
    await #expect(throws: GmailError.self) {
        _ = try await session.api.sendMessage(rawRFC822: Data("Subject: synthetic\r\n\r\nx".utf8), threadID: nil)
    }
    await #expect(throws: GmailError.self) {
        _ = try await session.api.createDraft(rawRFC822: Data("Subject: synthetic\r\n\r\nx".utf8), threadID: nil)
    }
    #expect(google.api.requests.dropFirst(wire).allSatisfy(isReadOnlyOnTheWire), "none of them reached Gmail")

    #expect(environment.draftsDirectory == nil)
    let window = environment.router
    window.start()
    await eventually("the window's account") { window.active != nil }
    let compose = environment.compose
    #expect(compose.recovery is InMemoryDraftRecovery)
    let composer = try #require(compose.openNew(placement: .modal))
    composer.to.text = "dana@example.org,"
    composer.updateBody(RichTextDocument(blocks: [.paragraph([.text("Synthetic", [])])]))
    await composer.settle()
    #expect(!composer.canPersist && composer.draftKey == nil)
    #expect(try store.drafts(account: nil, states: [], limit: 50).isEmpty)
    #expect(google.api.requests.allSatisfy(isReadOnlyOnTheWire))
}

@MainActor
@Test func everyOtherWriteModeIsRefusedAtLaunchForRealAccounts() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-home-\(UUID().uuidString)")
    let app = CompositionRoot.makeApp(arguments: [], environment: ["OPENHUMAN_SAFE_MODE": "write-allowlist",
                                                                   "OPENHUMAN_HOME": home.path])
    if case .notice(let problem) = app.screen {
        #expect(problem.title == LaunchSafeMode.refusalTitle)
    } else {
        Issue.record("expected the refusal notice")
    }
    #expect(app.session == nil)
    #expect(!FileManager.default.fileExists(atPath: home.path), "the store directory must not be created")
    #expect(throws: LaunchSafeMode.Refusal.self) { try LaunchSafeMode.environmentChoice(["OPENHUMAN_SAFE_MODE": "write-allowlist"]) }
    for value in ["read-only", "READ-ONLY", " read-only", "readonly", "read_only", "Read_Only", "write_allowlist",
                  "Write-Allowlist", "Normal", "NORMAL", " normal", "normal ", "garbage", " "] {
        #expect(try LaunchSafeMode.environmentChoice(["OPENHUMAN_SAFE_MODE": value]) == .environmentReadOnly, "\(value)")
        #expect(try LaunchSafeMode.forRealAccounts(environment: ["OPENHUMAN_SAFE_MODE": value], allowsChanges: true) == .readOnly,
                "\(value): read-only whatever the switch says")
    }
    for value in [nil, ""] as [String?] {
        let environment = value.map { ["OPENHUMAN_SAFE_MODE": $0] } ?? [:]
        #expect(try LaunchSafeMode.environmentChoice(environment) == .setting, "\(value ?? "unset")")
        #expect(try LaunchSafeMode.forRealAccounts(environment: environment) == .readOnly, "\(value ?? "unset"): switch off")
        #expect(try LaunchSafeMode.forRealAccounts(environment: environment, allowsChanges: true) == .normal,
                "\(value ?? "unset"): switch on")
    }
    #expect(try LaunchSafeMode.environmentChoice(["OPENHUMAN_SAFE_MODE": "normal"]) == .environmentNormal)
    #expect(try LaunchSafeMode.forRealAccounts(environment: ["OPENHUMAN_SAFE_MODE": "normal"]) == .normal, "the variable alone")
    #expect(LaunchSafeMode.forFakeGmail(environment: ["OPENHUMAN_SAFE_MODE": "normal"]) == .normal)
    #expect(LaunchSafeMode.forFakeGmail(environment: [:]) == .readOnly)
    #expect(SyncSession.draftsDirectory(URL(fileURLWithPath: "/tmp/x"), safeMode: .readOnly) == nil)
    #expect(SyncSession.draftsDirectory(URL(fileURLWithPath: "/tmp/x"), safeMode: .normal) == URL(fileURLWithPath: "/tmp/x"))
}

@Test func theWriteModeSwitchIsOnByDefaultButOffWhenSavedOffUnreadableOrInATestHost() throws {
    let store = try MailStore.openInMemoryForTesting()
    #expect(LiveWriteModeSwitch.read(store) == true, "on by default (WRITE-MODE-DEFAULT)")
    #expect(LiveWriteModeSwitch.atLaunch(store: store, environment: [:]) == false, "never under XCTest, default included")
    try store.setSetting(LiveWriteModeSwitch.key, false, scope: .global)
    #expect(LiveWriteModeSwitch.read(store) == false, "an explicitly saved off is kept")
    try store.setSetting(LiveWriteModeSwitch.key, true, scope: .global)
    #expect(LiveWriteModeSwitch.read(store) == true)
    #expect(LiveWriteModeSwitch.atLaunch(store: store, environment: [:]) == false, "never under XCTest")
    #expect(LiveWriteModeSwitch.key.name == "write_mode.allow_changes" && LiveWriteModeSwitch.key.isSafetyKey)
    try store.setSetting(SettingKey<String>(name: "write_mode.allow_changes", defaultValue: "", isSafetyKey: false), "yes",
                         scope: .global)
    #expect(LiveWriteModeSwitch.read(store) == false, "an unreadable value counts as off")
}

private enum AppSources {
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func all() throws -> [String: String] {
        let root = app.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var out: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            out[file.lastPathComponent] = text.joined(separator: "\n")
        }
        return out
    }

    static func files(_ sources: [String: String], matching pattern: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: pattern)
        return Set(sources.filter { regex.firstMatch(in: $0.value, range: NSRange($0.value.startIndex..., in: $0.value)) != nil }
            .map(\.key))
    }

    static func arguments(of name: String, in text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex
        while let open = text.range(of: name + "(", range: search..<text.endIndex) {
            var depth = 0
            var index = text.index(before: open.upperBound)
            var end = text.endIndex
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" { depth -= 1; if depth == 0 { end = index; break } }
                index = text.index(after: index)
            }
            out.append(String(text[open.upperBound..<end]))
            search = open.upperBound
        }
        return out
    }

    static func body(of signature: String, in text: String) -> String? {
        guard let start = text.range(of: signature) else { return nil }
        let rest = text[start.upperBound...]
        let next = rest.range(of: "\n    static func ") ?? rest.range(of: "\n    func ")
        return String(rest[..<(next?.lowerBound ?? rest.endIndex)])
    }
}

@Test func noPathInTheAppLetsARealAccountReachAWrite() throws {
    let sources = try AppSources.all()
    #expect(sources.count > 15, "found the app's sources")
    func text(_ file: String) throws -> String { try #require(sources[file], "\(file)") }
    func codeLines(_ text: String, containing needle: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(needle) }
    }

    let live = try #require(AppSources.body(of: "static func live(", in: try text("CompositionRoot.swift")))
    let check = try #require(live.range(of: "choice = try LaunchSafeMode.environmentChoice(environment)"))
    let opened = try #require(live.range(of: "MailStore.open("))
    #expect(check.lowerBound < opened.lowerBound, "the variable is checked before the Store opens")
    #expect(codeLines(live, containing: "allowsChanges:") == [
        "choice, allowsChanges: LiveWriteModeSwitch.atLaunch(store: store, environment: environment))",
    ])
    #expect(codeLines(live, containing: "LaunchSafeMode.forRealAccounts(") == ["let mode = LaunchSafeMode.forRealAccounts("])
    #expect(!live.contains("forFakeGmail") && !live.contains(".normal") && !live.contains(".writeAllowlist"))
    let backends = AppSources.arguments(of: "LiveBackend", in: live)
    #expect(backends.count == 1 && backends.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("safeMode: mode,") })
    #expect(AppSources.files(sources, matching: #"LiveBackend\("#) == ["CompositionRoot.swift"])
    #expect(AppSources.files(sources, matching: #"forFakeGmail\("#) == ["CompositionRoot.swift", "LaunchSafeMode.swift"])
    let launchSource = try text("LaunchSafeMode.swift")
    let choose = try #require(AppSources.body(of: "static func environmentChoice(", in: launchSource))
    #expect(codeLines(choose, containing: ".environmentNormal") == ["if raw == SafeMode.normal.rawValue { return .environmentNormal }"])
    #expect(codeLines(choose, containing: ".setting") == ["if raw.isEmpty { return .setting }"],
            "only an absent or empty variable leaves it to the switch; anything unrecognised is read-only")
    let launch = try #require(AppSources.body(of: "static func forRealAccounts(_ choice:", in: launchSource))
    #expect(codeLines(launch, containing: ".normal") == ["return .normal", "return allowsChanges ? .normal : .readOnly"])
    #expect(launch.contains("case .environmentNormal:\n            return .normal"))
    #expect(launch.contains("case .setting:\n            return allowsChanges ? .normal : .readOnly"))
    #expect(AppSources.files(sources, matching: #"atLaunch\("#) == ["CompositionRoot.swift", "WriteModeSwitch.swift"])
    #expect(AppSources.files(sources, matching: #"LiveWriteModeSwitch\("#) == ["CompositionRoot.swift"])
    #expect(AppSources.files(sources, matching: #"AppRelaunch\.relaunch\("#) == ["CompositionRoot.swift"])
    #expect(AppSources.files(sources, matching: #"allowChanges"#) == ["WriteModeSwitch.swift"])
    #expect(!(try text("FakeGmailLaunch.swift")).contains("WriteModeSwitch"), "FakeGmail never gets the switch")
    let switchSource = try text("WriteModeSwitch.swift")
    let atLaunch = try #require(AppSources.body(of: "nonisolated static func atLaunch(", in: switchSource))
    #expect(atLaunch.contains("guard environment[\"XCTestConfigurationFilePath\"] == nil,\n              ProcessInfo.processInfo.environment[\"XCTestConfigurationFilePath\"] == nil else { return false }"))
    #expect(codeLines(switchSource, containing: "?? false") == ["(try? store.setting(key, scope: .global)) ?? false"])
    let modelSource = try String(contentsOf: AppSources.app.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/OpenHumanMailCore/Sources/MailFeatures/Settings/WriteModeSettingModel.swift"), encoding: .utf8)
    #expect(codeLines(modelSource, containing: "save(true)") == ["guard save(true) else { return }"])
    let confirm = try #require(modelSource.range(of: "public func confirm() {"))
    let cancel = try #require(modelSource.range(of: "public func cancel() {"))
    let saveOn = try #require(modelSource.range(of: "guard save(true) else { return }"))
    #expect(confirm.upperBound < saveOn.lowerBound && saveOn.upperBound < cancel.lowerBound, "on is saved by the sheet only")
    #expect(modelSource.contains("public func confirm() {\n        guard isConfirming else { return }"))

    let backend = try text("LiveBackend.swift")
    #expect(Set(codeLines(backend, containing: ".normal")) == [
        "let sessionMode: SafeMode = mode == .normal && writes ? .normal : .readOnly",
        "writeMode: sessionMode == .normal, accounts: accounts, writeModeSwitch: writeModeSwitch)",
        "if safeMode == .normal, !token.grantedScopes.contains(GmailScope.modify) {",
    ])
    #expect(!backend.contains(".writeAllowlist"))
    #expect(backend.contains("let mode = safeMode"))
    #expect(AppSources.files(sources, matching: #"makeSession\(for:"#) == ["AppModel.swift"])
    let appModel = try text("AppModel.swift")
    #expect(codeLines(appModel, containing: "makeSession(for:") == ["let session = try backend.makeSession(for: account, writes: writes)"])
    #expect(codeLines(appModel, containing: ".normal") == [
        "startSession(account, backend: backend, writes: backend.safeMode == .normal && !openedReadOnly)",
    ])
    #expect(codeLines(appModel, containing: "writes: false") == ["self?.startSession(account, backend: backend, writes: false)"])
    #expect(AppSources.files(sources, matching: #"writes: true"#).isEmpty, "only the launch mode turns writes on")
    #expect(AppSources.files(sources, matching: #"WriteModeSession\("#) == ["SyncSession.swift"])
    #expect(AppSources.files(sources, matching: #"\.writesNow\s*="#) == ["LiveBackend.swift"])
    #expect(codeLines(backend, containing: "writesNow") == ["writeModeSwitch?.writesNow = session.environment.writeMode != nil"])

    #expect(AppSources.files(sources, matching: #"WriteAllowlistStore|WriteGuard\(|SafeModeTransport|allowlist:"#).isEmpty)
    #expect(AppSources.files(sources, matching: #"DenyListTransport\("#).isEmpty)
    #expect(AppSources.files(sources, matching: #"OneClickGuard\("#) == ["OneClickUnsubscribe.swift"])
    #expect(codeLines(try text("OneClickUnsubscribe.swift"), containing: "OneClickGuard(") == [
        "mode == .normal ? OneClickGuard(wrapping: transport) : ReadOnlyTransport(wrapping: transport)",
    ])
    #expect(AppSources.files(sources, matching: #"DefaultGmailClientFactory\("#) == ["FakeGmailLaunch.swift", "LiveBackend.swift"])
    let liveFactory = AppSources.arguments(of: "DefaultGmailClientFactory", in: backend)
    #expect(liveFactory.count == 1 && liveFactory.allSatisfy {
        $0.hasPrefix("safeMode: sessionMode,") && !$0.contains("storeDirectory") && !$0.contains("recipientGate")
    })
    for args in AppSources.arguments(of: "DefaultGmailClientFactory", in: try text("FakeGmailLaunch.swift")) {
        #expect(!args.contains("storeDirectory") && !args.contains("recipientGate"))
    }
    #expect(!(try text("FakeGmailLaunch.swift")).contains("writeMode"), "FakeGmail never gets the write-mode session")

    let packages = AppSources.app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Packages")
    let gmailSources = packages.appendingPathComponent("OpenHumanGmail/Sources/OpenHumanGmail")
    let wrap = try String(contentsOf: gmailSources.appendingPathComponent("SafeMode/SafeModeTransport.swift"), encoding: .utf8)
    #expect(wrap.contains("""
                case .normal:
                    if let guarded = transport as? DenyListTransport, guarded.recipients === recipients { return guarded }
                    return DenyListTransport(wrapping: transport, recipients: recipients)
        """))
    let factorySource = try String(contentsOf: gmailSources.appendingPathComponent("Client/DefaultGmailClientFactory.swift"),
                                   encoding: .utf8)
    #expect(factorySource.contains(
        "let transport = SafeModeTransport.wrap(apiTransport, mode: safeMode, grantedScopes: scopes, allowlist: allowlist,"))
    #expect(factorySource.contains("recipients: recipientGate)"))
    #expect(factorySource.components(separatedBy: "GmailClient(accountEmail:").count == 2, "one client construction")

    let endpoints = try String(contentsOf: gmailSources.appendingPathComponent("Client/GmailEndpoints.swift"), encoding: .utf8)
    let entry = try NSRegularExpression(pattern: #"GmailEndpoint\(httpMethod: "(\w+)", template: (api|upload) \+ "([^"]+)"\)"#)
    let table = entry.matches(in: endpoints, range: NSRange(endpoints.startIndex..., in: endpoints)).compactMap { match -> (String, String)? in
        guard let method = Range(match.range(at: 1), in: endpoints), let root = Range(match.range(at: 2), in: endpoints),
              let path = Range(match.range(at: 3), in: endpoints) else { return nil }
        let prefix = endpoints[root] == "api" ? "/gmail/v1/users/me/" : "/upload/gmail/v1/users/me/"
        return (String(endpoints[method]), prefix + endpoints[path].replacingOccurrences(of: "{id}", with: "x1"))
    }
    #expect(table.count >= 25, "read the client's endpoint table")
    for (method, path) in table {
        let request = HTTPRequest(method: method, url: URL(string: "https://gmail.googleapis.com" + path)!, headers: [:])
        #expect(DenyListTransport.refusalReason(for: request) == nil, "\(method) \(path) is one of the client's endpoints")
    }
    var everything = sources
    for package in ["OpenHumanCore", "OpenHumanGmail", "OpenHumanStore", "OpenHumanSync", "OpenHumanCLI"] {
        let root = packages.appendingPathComponent(package).appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files where !file.path.contains("/OpenHumanGmailTesting/") {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            everything["\(package)/\(file.lastPathComponent)"] = code
        }
    }
    let guards: Set<String> = ["OpenHumanGmail/DenyListTransport.swift", "OpenHumanGmail/WriteGuard.swift",
                               "OpenHumanGmail/ReadOnlyTransport.swift", "OpenHumanGmail/GmailEndpoints.swift",
                               "OpenHumanGmail/CalendarGuardTransport.swift"]
    let callers = AppSources.files(everything, matching: #""DELETE""#).subtracting(guards)
    #expect(callers == ["OpenHumanGmail/GmailClient.swift", "OpenHumanGmail/GoogleCalendarClient.swift"])
    let deletes = codeLines(try #require(everything["OpenHumanGmail/GmailClient.swift"]), containing: "\"DELETE\"")
    #expect(deletes.count == 1 && deletes.allSatisfy { $0.contains(".deleteDraft") && $0.contains("drafts/") })
    let calendarDeletes = codeLines(try #require(everything["OpenHumanGmail/GoogleCalendarClient.swift"]),
                                    containing: "\"DELETE\"")
    #expect(calendarDeletes.count == 2 && calendarDeletes.allSatisfy { $0.contains("\"events\", id]") })
    let guardedRemovals = calendarDeletes.filter { $0.contains("extraHeaders") || $0.contains("isWrite: true") }
    #expect(guardedRemovals.count == 1, "only the card's Delete is a write that asks for the organizer rule")
    let deniedPath = #""[^"\n]*/?\b(batchDelete|emptyTrash|emptySpam|forwardingAddresses|autoForwarding|delegates|vacation|settings/filters|settings/imap|settings/pop|settings/language|messages/import)\b[^"\n]*""#
    #expect(AppSources.files(everything, matching: deniedPath).subtracting(guards).isEmpty)
    #expect(AppSources.files(everything, matching: #"write_mode\.allow_changes"#).isEmpty)

    let gmailWrites = #"\b(api|client|gmail|session\.api)\s*\.\s*(batchModifyMessages|modifyMessage|modifyThread|trashThread|untrashThread|trashMessage|untrashMessage|sendMessage|createDraft|updateDraft|deleteDraft|sendDraft|insertMessage|createLabel)\("#
    #expect(AppSources.files(sources, matching: gmailWrites).isEmpty)

    let engineWrites = #"engine(\(\))?\s*\.\s*(perform|undo|newDraft|saveDraft|flushDraft|discardDraft|setReviewState|send|sendNow|scheduleSend|cancelScheduledSend|cancelSend|createLabel|createAgentDraft|updateAgentDraft|upsertSnippet|deleteSnippet|recordSnippetUse|upsertSplit|deleteSplit|reorderSplits|resolveDraftConflict|dismissFailedOperation)\("#
    #expect(AppSources.files(sources, matching: engineWrites) == ["MailStoreCommands.swift"])
    let storeWrites = #"store\s*\.\s*(apply|undo|createDraft|updateDraft|updateAgentDraft|saveDraftRemotely|discardDraft|setReviewState|send|scheduleSend|cancelScheduledSend|cancelSend|sendNow|resolveDraftConflict|upsertSnippet|deleteSnippet|recordSnippetUse|upsertSplit|deleteSplit|reorderSplits|dismissFailedOperation)\("#
    #expect(AppSources.files(sources, matching: storeWrites) == ["MailStoreCommands.swift"])
    #expect(AppSources.files(sources, matching: #"flushPendingSends\("#) == ["SyncSession.swift"])

    let session = try text("SyncSession.swift")
    #expect(AppSources.files(sources, matching: #"MailStoreCommands\("#) == ["SyncSession.swift"])
    #expect(session.contains("safeMode = try wiring.factory.effectiveMode(for: item.email)"))
    #expect(session.contains("let mode = SafeModeInfo(safeMode)"))
    #expect(session.contains("let writeMode = mode == .normal && wiring.writeMode ? WriteModeSession() : nil"))
    #expect(session.contains("MailStoreCommands(engine: { try slot.engine() }, safeMode: mode, oneClick: oneClick)"))
    #expect(session.contains("let effectiveMode: SafeMode = safeMode")
            && session.contains("OneClickUnsubscribe(store: store, transport: transport, mode: effectiveMode)"),
            "the one-click transport is guarded for the account's effective mode")
    #expect(session.contains("safeMode: wiring.factory.safeMode)"), "the engine's policy is the factory's (session) mode")
    #expect(AppSources.files(sources, matching: #"MailEngine\("#) == ["SyncSession.swift"])

    let model = AppSources.app.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/OpenHumanMailCore/Sources/MailModel")
    let requirements = try ["Commands.swift", "UndoToken.swift"].flatMap { file -> [String] in
        let protocolText = try String(contentsOf: model.appendingPathComponent(file), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"(?m)^\s+func (\w+)\("#)
        return regex.matches(in: protocolText, range: NSRange(protocolText.startIndex..., in: protocolText)).compactMap {
            Range($0.range(at: 1), in: protocolText).map { String(protocolText[$0]) }
        }
    }
    #expect(Set(requirements) == Set(portCalls.map(\.name)), "the call table covers the whole port")
    let port = try text("MailStoreCommands.swift")
    var guarded: [String: String] = [:]
    let lines = port.components(separatedBy: "\n")
    let signature = try NSRegularExpression(pattern: #"^    public func (\w+)\("#)
    for (index, line) in lines.enumerated() {
        guard let match = signature.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { continue }
        let name = line[range]
        guard let open = lines[index...].firstIndex(where: { $0.hasSuffix("{") }) else { continue }
        let first = lines[(open + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guarded[String(name)] = first
    }
    for name in requirements {
        let first = try #require(guarded[name], "MailStoreCommands implements \(name)")
        if readThroughs.contains(name) {
            #expect(!first.hasPrefix("try require"), "\(name) is a read-through")
        } else if sends.contains(name) {
            #expect(first.hasPrefix("try requireSending("), "\(name) refuses outside normal mode first")
        } else {
            #expect(first.hasPrefix("try requireChanges(") || first.hasPrefix("try requireSending("),
                    "\(name) refuses in read-only first")
        }
    }
    #expect(port.contains("guard safeMode != .readOnly else") && port.contains("guard safeMode == .normal else"))

    #expect(AppSources.files(sources, matching: #"GoogleCalendarSession\("#) == ["LiveBackend.swift"])
    #expect(codeLines(backend, containing: "GoogleCalendarSession(").allSatisfy { $0.contains("mode: sessionMode,") })
    #expect(AppSources.files(sources, matching: #"GoogleCalendarClient\("#) == ["GoogleCalendarSession.swift"])
    #expect(AppSources.files(sources, matching: #"GoogleCalendarProvider\("#) == ["GoogleCalendarSession.swift"])
    #expect(AppSources.files(sources, matching: #"CalendarGuardTransport|CalendarScope\.|include_granted"#).isEmpty)
    #expect(!(try text("FakeGmailLaunch.swift")).contains("calendar"))
    #expect(try text("CompositionRoot.swift").contains("guard !arguments.contains(\"-UseFakeCalendar\") else { return nil }"))
    #expect(AppSources.files(sources, matching: #"calendarTokenStore: liveCalendarTokenStore\("#) == ["CompositionRoot.swift"])
    #expect(codeLines(try text("LiveAccountManager.swift"), containing: "makeFlow(client, mode:").allSatisfy {
        $0.contains("mode: session.safeMode)") || $0.contains("mode: safeMode)")
    })
}
