import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanCLIKit

func commandArguments(_ path: String, draftID: String = "d1") -> [String] {
    switch path {
    case "accounts.alias": return ["accounts", "alias", "me@example.com", "mine"]
    case "accounts.default": return ["accounts", "default", "me@example.com"]
    case "sync.run": return ["sync", "run"]
    case "config.set": return ["config", "set", "undo_send_seconds", "5"]
    case "gmail.snooze": return ["gmail", "snooze", "t1", "--until", "+2h"]
    case "gmail.remind": return ["gmail", "remind", "t1", "--at", "+2h"]
    case "gmail.drafts.create": return ["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "hi"]
    case "gmail.drafts.reply": return ["gmail", "drafts", "reply", "m1", "--body", "hi"]
    case "gmail.drafts.update": return ["gmail", "drafts", "update", draftID, "--body", "hi"]
    case "gmail.review.show", "gmail.drafts.delete": return path.split(separator: ".").map(String.init) + [draftID]
    case "gmail.drafts.forward": return ["gmail", "drafts", "forward", "m1", "--to", "a@example.com"]
    case "gmail.thread.modify": return ["gmail", "thread", "modify", "t1", "--add", "Clients"]
    case "gmail.batch.modify": return ["gmail", "batch", "modify", "--ids", "m1", "--add", "Clients"]
    case "gmail.labels.create": return ["gmail", "labels", "create", "Foo"]
    case "gmail.splits.create": return ["gmail", "splits", "create", "Foo"]
    case "gmail.splits.update", "gmail.splits.delete": return path.split(separator: ".").map(String.init) + ["Important"]
    case "gmail.splits.reorder": return ["gmail", "splits", "reorder", "Important"]
    case "gmail.review.approve", "gmail.review.reject", "gmail.review.open": return path.split(separator: ".").map(String.init) + [draftID]
    case "gmail.snippets.list", "mcp", "calendar.events", "sync.watch": return path.split(separator: ".").map(String.init)
    case "accounts.add": return ["accounts", "add"]
    case "accounts.remove": return ["accounts", "remove", "me@example.com"]
    case "auth.login": return ["auth", "login"]
    case "auth.logout": return ["auth", "logout", "me@example.com"]
    case "gmail.history": return ["gmail", "history", "--since", "1"]
    case "gmail.attachments.get": return ["gmail", "attachments", "get", "m1", "1"]
    case "gmail.snippets.show", "gmail.snippets.render", "gmail.snippets.delete": return path.split(separator: ".").map(String.init) + ["sig"]
    case "gmail.snippets.add": return ["gmail", "snippets", "add", "Thanks", "--body", "Thank you"]
    case "gmail.snippets.export": return ["gmail", "snippets", "export"]
    case "gmail.snippets.import": return ["gmail", "snippets", "import", "/nonexistent/openhuman-snippets.json"]
    case "gmail.undo": return ["gmail", "undo", harmlessUndoToken]
    default:
        let parts = path.split(separator: ".").map(String.init)
        return parts + (parts[0] == "gmail" ? ["t1"] : [])
    }
}

let harmlessUndoToken: String = {
    let data = (try? JSONEncoder().encode(ActionReceipt(operationIDs: [], undo: .markRead([])))) ?? Data()
    return data.base64EncodedString()
}()

struct Snapshot: Equatable {
    var ops: Int
    var drafts: Int
    var reminders: Int
    var syncRequest: Int?
    var defaultAccount: String?
    var alias: String?
    var undoSend: Int
    var threads: [String]
    var snippets: Int

    init(_ h: Harness) throws {
        ops = try h.operations().count
        drafts = try h.store.drafts(account: nil, states: [], limit: 500).count
        reminders = try h.store.activeReminders(account: nil, limit: 100).count
        syncRequest = try h.store.setting(.syncRequestAt, scope: .global)
        defaultAccount = try h.store.setting(.defaultAccount, scope: .global)
        alias = try h.store.accounts().first?.alias
        undoSend = try h.store.setting(.undoSendSeconds, scope: .global)
        threads = try h.store.threadPage(view: .system(h.account, .inbox), after: nil, limit: 50).items.map {
            "\($0.ref.gmailThreadID.rawValue):\($0.isUnread):\($0.isStarred)"
        }
        snippets = try h.store.snippets(account: nil).count
    }
}

@Suite struct PolicyMatrixTests {
    static let writing = CommandCatalog.entries.filter { $0.writes != .none && $0.reserved == nil }
    static let network = CommandCatalog.entries.filter { $0.network }
    static let reserved = CommandCatalog.entries.filter { $0.reserved != nil }

    func harnessWithDraft() throws -> (Harness, String) {
        let h = try Harness()
        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: "S",
                                                                  bodyHTML: "<div>hi</div>", bodyText: "hi", attachments: []),
                                            origin: .cli, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        return (h, draft.rawValue)
    }

    @Test func readonlyFlagBlocksEveryWriteBeforeAnythingHappens() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        for meta in Self.writing where !meta.network {
            for env in [Harness.write, ["OPENHUMAN_SAFE_MODE": "normal"]] {
                let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--readonly", "--json"], environment: env)
                #expect(r.code == 5 && r.errorCode == "readonly", "\(meta.path): \(r.code) \(r.err)")
            }
        }
        #expect(try Snapshot(h) == before)
        let viaEnv = await h.run(["gmail", "done", "t1", "--json"], environment: Harness.write.merging(["OPENHUMAN_READONLY": "1"]) { $1 })
        #expect(viaEnv.code == 5)
        try h.store.setSetting(.cliReadonlyDefault, true, scope: .global)
        let viaSetting = await h.run(["gmail", "done", "t1", "--json"], environment: Harness.write)
        #expect(viaSetting.code == 5 && viaSetting.errorCode == "readonly")
        #expect(try Snapshot(h).ops == before.ops)
        #expect((await h.run(["gmail", "inbox", "--json"])).code == 0)
    }

    @Test func readOnlySafeModeIsTheDefaultAndBlocksEveryMailWrite() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        let blocked = Self.writing.filter { $0.writes == .mail && !$0.network }
        #expect(blocked.count >= 15)
        for meta in blocked {
            for env: [String: String] in [[:], ["OPENHUMAN_SAFE_MODE": ""], ["OPENHUMAN_SAFE_MODE": "read-only"]] {
                let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--json"], environment: env)
                #expect(r.code == 5 && r.errorCode == "blocked_by_safe_mode", "\(meta.path) under \(env): \(r.code) \(r.err)")
            }
        }
        for typo in ["bogus", "Normal", "NORMAL", " normal", "normal ", "write_allowlist"] {
            let r = await h.run(["gmail", "done", "t1", "--json"], environment: ["OPENHUMAN_SAFE_MODE": typo])
            #expect(r.code == 5 && r.errorCode == "blocked_by_safe_mode", "\(typo): \(r.code) \(r.err)")
        }
        #expect(try Snapshot(h) == before)
        let read = await h.run(["gmail", "inbox", "--json"], environment: ["OPENHUMAN_SAFE_MODE": "bogus"])
        #expect(read.code == 0, "reads still work: \(read.err)")
    }

    @Test func writeAllowlistBlocksEveryMailWriteAndQueuesNothing() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        let blocked = Self.writing.filter { $0.writes == .mail && !$0.network }
        for meta in blocked {
            let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--json"],
                                environment: ["OPENHUMAN_SAFE_MODE": "write-allowlist"])
            #expect(r.code == 5 && r.errorCode == "blocked_by_safe_mode", "\(meta.path): \(r.code) \(r.err)")
            #expect(!r.err.contains("OPENHUMAN_SAFE_MODE=") && !"\(r.error)".contains("OPENHUMAN_SAFE_MODE="), "\(meta.path)")
        }
        #expect(try Snapshot(h) == before)
        let readOnly = await h.run(["gmail", "done", "t1", "--json"])
        #expect(readOnly.errorCode == "blocked_by_safe_mode" && !"\(readOnly.error)".contains("OPENHUMAN_SAFE_MODE="))
    }

    @Test func dryRunNeverWritesAndNeverNeedsTheWriteMode() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        for meta in Self.writing where meta.implemented && meta.writes == .mail {
            for env in [[String: String](), Harness.write] {
                let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--dry-run", "--json"], environment: env)
                #expect(r.code == 0, "\(meta.path) \(env): \(r.code) \(r.err)")
                #expect(r.data["dryRun"] as? Bool == true, "\(meta.path)")
            }
        }
        for meta in Self.writing where !meta.implemented && !meta.network {
            let r = await h.run(commandArguments(meta.path, draftID: draft) + (meta.confirm ? ["--yes"] : []) + ["--dry-run", "--json"],
                                environment: Harness.write)
            #expect(r.code == 13, "\(meta.path): \(r.code)")
        }
        #expect(try Snapshot(h) == before)
    }

    @Test func notBuiltCommandsExit13WithoutWriting() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        let planned = CommandCatalog.entries.filter { !$0.implemented && !$0.network && $0.reserved == nil }
        #expect(planned.count >= 10)
        for meta in planned {
            let r = await h.run(commandArguments(meta.path, draftID: draft) + (meta.confirm ? ["--yes"] : []) + ["--json"], environment: Harness.write)
            #expect(r.code == 13 && r.errorCode == "not_implemented", "\(meta.path): \(r.code) \(r.err)")
        }
        #expect(try Snapshot(h) == before)
    }

    @Test func networkCommandsExit12InPhase1() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        #expect(Self.network.count >= 7)
        for meta in Self.network {
            for env in [[String: String](), Harness.write] {
                let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--json"], environment: env)
                #expect(r.code == 12 && r.errorCode == "app_required", "\(meta.path): \(r.code)")
            }
        }
        for flags in [["--sync"], ["--remote"]] {
            let r = await h.run(["gmail", "search", "x"] + flags + ["--json"])
            #expect(r.code == 12)
        }
        #expect(try Snapshot(h) == before)
    }

    @Test func reservedSendNamesExit5AndWriteNothing() async throws {
        let (h, draft) = try harnessWithDraft()
        let before = try Snapshot(h)
        #expect(Set(Self.reserved.map(\.path)) == ["gmail.send", "gmail.reply", "gmail.reply-all", "gmail.forward", "gmail.drafts.send", "gmail.filters"])
        let argv: [String: [String]] = [
            "gmail.send": ["gmail", "send", "--to", "a@example.com", "--subject", "x", "--body", "y"],
            "gmail.reply": ["gmail", "reply", "m1", "--body", "y"], "gmail.reply-all": ["gmail", "reply-all", "m1"],
            "gmail.forward": ["gmail", "forward", "m1", "--to", "a@example.com"], "gmail.drafts.send": ["gmail", "drafts", "send", draft],
            "gmail.filters": ["gmail", "filters", "create", "--from", "x"],
        ]
        for meta in Self.reserved {
            for env in [[String: String](), Harness.write, ["OPENHUMAN_SAFE_MODE": "normal"]] {
                let r = await h.run(argv[meta.path]! + ["--json"], environment: env)
                let expected = meta.path == "gmail.filters" ? "not_supported" : "send_not_supported"
                #expect(r.code == 5 && r.errorCode == expected, "\(meta.path): \(r.code) \(r.err)")
            }
        }
        #expect((await h.run(["gmail", "send", "--json"])).error["message"] as? String != nil)
        #expect(try Snapshot(h) == before)
    }

    @Test func theAllowlistLimitsWhichCommandsRun() async throws {
        let (h, draft) = try harnessWithDraft()
        try h.store.setSetting(.cliAllowedCommands, ["gmail.search", "gmail.drafts.create"], scope: .global)
        let before = try Snapshot(h)
        #expect((await h.run(["gmail", "search", "invoice", "--json"])).code == 0)
        let blocked = await h.run(["gmail", "inbox", "--json"])
        #expect(blocked.code == 5 && blocked.errorCode == "command_not_allowed")
        for meta in Self.writing where meta.implemented && meta.path != "gmail.drafts.create" {
            let r = await h.run(commandArguments(meta.path, draftID: draft) + ["--json"], environment: Harness.write)
            #expect(r.code == 5 && r.errorCode == "command_not_allowed", "\(meta.path)")
        }
        #expect((await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "hi", "--json"],
                             environment: Harness.write)).code == 6)
        #expect(try Snapshot(h).ops == before.ops + 1)
        try h.store.setSetting(.cliAllowedCommands, ["gmail.done"], scope: .global)
        #expect((await h.run(["gmail", "archive", "t2", "--json"], environment: Harness.write)).code == 6)
    }

    @Test func confirmationIsRequiredUnderNoInput() throws {
        let trash = try #require(CommandCatalog.meta(for: "gmail.trash"))
        let inputs = PolicyInputs(readonly: false, safeMode: .normal, allowedCommands: nil, noInput: true, yes: false, dryRun: false)
        #expect(throws: CLIError.self) { try Policy.evaluate(trash, path: "gmail.trash", inputs) }
        do { try Policy.evaluate(trash, path: "gmail.trash", inputs) } catch let error as CLIError {
            #expect(error.status == .usage && error.code == "confirmation_required")
        }
        var yes = inputs
        yes.yes = true
        do { try Policy.evaluate(trash, path: "gmail.trash", yes) } catch let error as CLIError { #expect(error.status == .notImplemented) }
    }
}

@Suite struct ExitCodeMappingTests {
    static let storeErrors: [(StoreError, CLIStatus)] = [
        (.notFound("x"), .notFound), (.readOnly, .policyBlocked), (.busy, .busy),
        (.schemaTooNew(found: 9, supported: 1), .incompatible), (.sqliteMissingFeature("fts5"), .incompatible),
        (.invalidQuery("q", position: 1), .usage), (.unsupportedView("v"), .usage), (.conflict("c"), .failure),
        (.accountNotActive(AccountID(1)), .authRequired), (.integrity("i"), .failure), (.reservedLabel("OpenHuman/Snoozed"), .policyBlocked),
        (.limitExceeded("l"), .failure),
    ]
    static let engineErrors: [(EngineError, CLIStatus)] = [
        (.requiresApp("x"), .appRequired), (.sendNotAllowed, .policyBlocked), (.oauthClientMissing, .appRequired),
        (.blockedBySafeMode("x"), .policyBlocked),
    ]

    @Test(arguments: storeErrors) func storeErrorsMapToTheTable(_ error: StoreError, _ expected: CLIStatus) {
        let mapped = CLIError.map(error)
        #expect(mapped.status == expected)
    }

    @Test(arguments: engineErrors) func engineErrorsMapToTheTable(_ error: EngineError, _ expected: CLIStatus) {
        #expect(CLIError.map(error).status == expected)
    }

    @Test func messagesNeverCarryTheUnderlyingText() {
        let secret = "SECRET-SUBJECT-xyz"
        for error in [StoreError.notFound(secret), .invalidQuery(secret, position: 0), .conflict(secret), .integrity(secret),
                      .reservedLabel(secret), .limitExceeded(secret), .unsupportedView(secret), .sqliteMissingFeature(secret)] {
            let mapped = CLIError.map(error)
            #expect(!mapped.message.contains(secret) && !mapped.details.values.contains { $0 == .string(secret) })
        }
        for error in [EngineError.requiresApp(secret), .blockedBySafeMode(secret)] {
            #expect(!CLIError.map(error).message.contains(secret))
        }
        struct Odd: Error {}
        #expect(CLIError.map(Odd()).status == .failure)
        #expect(CLIError.map(WhenParserError.unrecognized(secret)).status == .usage)
        #expect(!CLIError.map(WhenParserError.unrecognized(secret)).message.contains(secret))
    }

    @Test func everyExitStatusIsDistinctAndDocumented() {
        #expect(CLIStatus.allCases.map(\.rawValue) == Array(0...13))
        #expect(Set(CLIStatus.allCases.map(\.label)).count == 14)
        #expect(CLIStatus.queued.label == "queued" && CLIStatus.notImplemented.rawValue == 13)
    }

    @Test func schemaTooNewReachesTheProcessAsExit9() async throws {
        let h = try Harness()
        try h.store.close()
        let db = h.directory.appendingPathComponent("mail.sqlite")
        let bumped = try bumpCompatLevel(db)
        #expect(bumped)
        let r = await h.run(["gmail", "inbox", "--json"])
        #expect(r.code == 9 && r.errorCode == "schema_too_new")
    }

    func bumpCompatLevel(_ db: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, "UPDATE schema_info SET compat_level = 999 WHERE id = 1;"]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
