import Foundation
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanCLIKit

func token(_ receipt: ActionReceipt) throws -> String {
    try JSONEncoder().encode(receipt).base64EncodedString()
}

@Suite struct UndoCommandTests {
    static let env = Harness.write

    @Test func undoTakesBackADoneThatIsStillQueued() async throws {
        let h = try Harness()
        let done = await h.run(["gmail", "done", "t1", "--json"], environment: Self.env)
        let undo = try #require(done.data["undo"] as? String)
        let op = try #require(try h.operations([.pending]).first)
        let r = await h.run(["gmail", "undo", undo, "--json"], environment: Self.env)
        #expect(r.code == 0 && r.data["verb"] as? String == "undo" && r.data["threadIds"] as? [String] == ["t1"], "\(r.code) \(r.err)")
        #expect(try h.store.operation(op.id)?.status == .cancelled)
        let inbox = await h.run(["gmail", "inbox", "--json"])
        #expect(inbox.list("threads").contains { $0["threadId"] as? String == "t1" })
        #expect(!(try h.operations()).contains { $0.kind == .sendDraft })
        let again = await h.run(["gmail", "done", "t2", "--json"], environment: Self.env)
        let before = try h.operations().count
        let dry = await h.run(["gmail", "undo", try #require(again.data["undo"] as? String), "--dry-run", "--json"])
        #expect(dry.code == 0 && dry.data["dryRun"] as? Bool == true && dry.data["threadIds"] as? [String] == ["t2"])
        #expect(try h.operations().count == before)
    }

    @Test func aForgedTokenCanDoNoMoreThanTheTriageCommands() async throws {
        let h = try Harness()
        let ref = try h.threadRef("t1")
        let before = try h.operations().count
        func undo(_ text: String) async -> Run { await h.run(["gmail", "undo", text, "--json"], environment: Self.env) }
        for action: MailAction in [.trash([ref]), .markSpam([ref]), .modifyLabels([ref], add: [GmailLabelID("Label_1")], remove: []),
                                   .createLabel(h.account, name: "X", applyTo: [ref]),
                                   .modifyMessageLabels(h.account, [GmailMessageID("m1")], add: [GmailLabelID("TRASH")], remove: [])] {
            let r = await undo(try token(ActionReceipt(operationIDs: [], undo: action)))
            #expect(r.code == 5 && r.errorCode == "undo_not_allowed", "\(action): \(r.code)")
        }
        let appReceipt = try h.store.apply(.archive([try h.threadRef("t2")]), origin: .app)
        let appOp = try #require(appReceipt.operationIDs.first)
        let refused = await undo(try token(appReceipt))
        #expect(refused.code == 5 && refused.errorCode == "undo_not_allowed")
        #expect(try h.store.operation(appOp)?.status == .pending)
        let wrongRow = ThreadRef(accountID: ref.accountID, rowID: ThreadRowID(rawValue: ref.rowID.rawValue + 999), gmailThreadID: ref.gmailThreadID)
        #expect((await undo(try token(ActionReceipt(operationIDs: [], undo: .moveToInbox([wrongRow]))))).errorCode == "bad_undo_token")
        #expect((await undo("not-a-token")).errorCode == "bad_undo_token")
        #expect((await undo(try token(ActionReceipt(operationIDs: [], undo: nil)))).errorCode == "bad_undo_token")
        #expect(try h.operations().count == before + appReceipt.operationIDs.count)
        let blocked = await h.run(["gmail", "undo", harmlessUndoToken, "--json"])
        #expect(blocked.code == 5 && blocked.errorCode == "blocked_by_safe_mode")
    }
}

final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

struct McpSession {
    var code: Int32
    var stdout: String
    var err: String
    var replies: [[String: Any]] {
        stdout.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
    func reply(_ id: Int) -> [String: Any] { replies.first { ($0["id"] as? Int) == id } ?? [:] }
    func result(_ id: Int) -> [String: Any] { reply(id)["result"] as? [String: Any] ?? [:] }
    func errorCode(_ id: Int) -> Int? { (reply(id)["error"] as? [String: Any])?["code"] as? Int }
    func envelope(_ id: Int) -> [String: Any] {
        let content = result(id)["content"] as? [[String: Any]] ?? []
        guard let text = content.first?["text"] as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    func notes(_ id: Int) -> String {
        let content = result(id)["content"] as? [[String: Any]] ?? []
        return content.dropFirst().compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

func rpc(_ id: Int?, _ method: String, _ params: [String: Any] = [:]) -> String {
    var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    if let id { message["id"] = id }
    return String(decoding: (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

func call(_ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) -> String {
    rpc(id, "tools/call", ["name": tool, "arguments": arguments])
}

func mcp(_ h: Harness, _ lines: [String], args: [String] = [], environment: [String: String] = Harness.write) async -> McpSession {
    let queue = LineQueue(lines)
    let out = BufferSink(), err = BufferSink()
    var variables = h.allowedEnvironment
    for (k, v) in environment { variables[k] = v }
    let env = CLIEnvironment(variables: variables, stdout: out, stderr: err, stdoutIsTTY: false, stdinIsTTY: false, clock: h.clock,
                             timeZone: TimeZone(identifier: "UTC")!, nonce: { "3f9a1c" }, readLine: { queue.next() })
    let code = await OpenHumanCLI.run(["mcp"] + args, environment: env)
    return McpSession(code: code, stdout: out.text, err: err.text)
}

@Suite struct McpServerTests {
    static let readTools = [
        "accounts_list", "gmail_search", "gmail_list", "gmail_inbox", "gmail_get", "gmail_thread_get", "gmail_labels_list", "gmail_counts",
        "gmail_splits_list", "gmail_drafts_list", "gmail_drafts_get", "gmail_review_list", "gmail_snippets_list", "gmail_snippets_show",
        "gmail_snippets_render", "sync_status",
    ]
    static let writeTools = [
        "gmail_drafts_create", "gmail_drafts_update", "gmail_drafts_reply",
        "gmail_done", "gmail_move_to_inbox", "gmail_read", "gmail_unread", "gmail_star", "gmail_unstar", "gmail_snooze", "gmail_unsnooze",
        "gmail_remind", "gmail_unremind", "undo",
    ]
    static let notExposed: Set<String> = [
        "gmail.send", "gmail.reply", "gmail.reply-all", "gmail.forward", "gmail.drafts.send", "gmail.trash", "gmail.untrash", "gmail.spam",
        "gmail.not-spam", "gmail.thread.modify", "gmail.batch.modify", "gmail.labels.create", "gmail.splits.create", "gmail.splits.update",
        "gmail.splits.delete", "gmail.splits.reorder", "gmail.drafts.delete", "gmail.drafts.forward", "gmail.review.approve",
        "gmail.review.reject", "accounts.add", "accounts.remove", "auth.login", "auth.logout", "config.set", "sync.run", "gmail.history",
        "gmail.attachments.get", "calendar.events", "gmail.snippets.add", "gmail.snippets.delete", "gmail.snippets.import",
    ]

    func listed(_ h: Harness, _ args: [String] = [], environment: [String: String] = Harness.write) async -> [String] {
        let r = await h.run(["mcp", "--list-tools", "--json"] + args, environment: environment)
        return r.list("tools").compactMap { $0["name"] as? String }
    }

    @Test func theToolListIsPinnedPerModeAndHasNoSendTool() async throws {
        let h = try Harness()
        #expect(await listed(h) == Self.readTools + Self.writeTools)
        #expect(await listed(h, environment: [:]) == Self.readTools)
        #expect(await listed(h, environment: ["OPENHUMAN_SAFE_MODE": "write-allowlist"]) == Self.readTools)
        #expect(await listed(h, ["--readonly"]) == Self.readTools)
        #expect(await listed(h, environment: Harness.write.merging(["OPENHUMAN_READONLY": "1"]) { $1 }) == Self.readTools)
        for tool in McpTools.all {
            let meta = try #require(CommandCatalog.meta(for: tool.path), "\(tool.name)")
            #expect(meta.implemented && meta.reserved == nil && !meta.network, "\(tool.name)")
            #expect(!Self.notExposed.contains(meta.path), "\(tool.name) runs \(meta.path)")
            #expect(tool.group == .read ? meta.writes == .none : meta.writes == .mail, "\(tool.name)")
            #expect(!tool.name.contains("send") && tool.name.allSatisfy { $0.isLowercase || $0 == "_" }, "\(tool.name)")
        }
        try h.store.setSetting(.cliReadonlyDefault, true, scope: .global)
        #expect(await listed(h) == Self.readTools)
        try h.store.setSetting(.cliReadonlyDefault, false, scope: .global)
        try h.store.setSetting(.cliAllowedCommands, ["mcp", "gmail.search", "gmail.archive"], scope: .global)
        #expect(await listed(h) == ["gmail_search", "gmail_done"])
        try h.store.setSetting(.cliAllowedCommands, ["gmail.search"], scope: .global)
        let refused = await mcp(h, [rpc(1, "initialize", ["protocolVersion": "2025-06-18"])])
        #expect(refused.code == 5 && refused.stdout.isEmpty && refused.err.contains("command_not_allowed"))
    }

    @Test func aSessionInitializesListsAndCallsReadTools() async throws {
        let h = try Harness()
        let s = await mcp(h, [
            rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "1"]]),
            rpc(nil, "notifications/initialized"),
            rpc(2, "ping"),
            rpc(3, "tools/list"),
            call(4, "gmail_search", ["query": "invoice"]),
            call(5, "no_such_tool"),
            rpc(6, "resources/list"),
            "this is not json",
            rpc(7, "initialize", ["protocolVersion": "1999-01-01"]),
            call(8, "gmail_get", ["messageId": "m1", "bogus": true]),
            call(9, "gmail_thread_get", ["threadId": "t1", "format": "text", "bodies": true]),
            call(10, "gmail_list", ["max": "ten"]),
        ])
        #expect(s.code == 0)
        let lines = s.stdout.split(separator: "\n")
        #expect(lines.count == 11 && lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) is [String: Any] })
        let initialize = s.result(1)
        #expect(initialize["protocolVersion"] as? String == "2025-06-18")
        #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "openhuman")
        #expect((initialize["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((initialize["instructions"] as? String)?.contains("untrusted") == true)
        #expect(s.reply(2)["result"] is [String: Any])
        let tools = s.result(3)["tools"] as? [[String: Any]] ?? []
        #expect(tools.compactMap { $0["name"] as? String } == Self.readTools + Self.writeTools)
        let search = try #require(tools.first { $0["name"] as? String == "gmail_search" })
        #expect(((search["inputSchema"] as? [String: Any])?["required"] as? [String]) == ["query"])
        #expect((search["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)

        #expect(s.result(4)["isError"] as? Bool == false)
        let envelope = s.envelope(4)
        #expect(envelope["ok"] as? Bool == true && envelope["command"] as? String == "gmail.search")
        #expect((envelope["meta"] as? [String: Any])?["untrustedNonce"] as? String == "3f9a1c")
        let first = ((envelope["data"] as? [String: Any])?["threads"] as? [[String: Any]])?.first
        #expect((first?["subject"] as? String)?.hasPrefix("⟦untrusted:3f9a1c⟧") == true)
        #expect(s.errorCode(5) == -32602)
        #expect(s.errorCode(6) == -32601)
        #expect(s.replies.contains { $0["id"] is NSNull && ($0["error"] as? [String: Any])?["code"] as? Int == -32700 })
        #expect(s.result(7)["protocolVersion"] as? String == "2025-06-18")
        #expect(s.errorCode(8) == -32602)
        #expect(s.result(9)["isError"] as? Bool == false && s.envelope(9)["command"] as? String == "gmail.thread.get")
        #expect(s.errorCode(10) == -32602)
        #expect(s.err.contains("mcp: tool gmail_search exit 0") && !s.err.contains("invoice"))
    }

    @Test func draftAndTriageToolsGoThroughThePolicyAndUndo() async throws {
        let h = try Harness()
        let s = await mcp(h, [
            call(1, "gmail_drafts_create", ["to": ["a@example.com"], "subject": "Hi", "body": "--not an option\nline two", "note": "check"]),
            call(2, "gmail_done", ["threadIds": ["t1"]]),
            call(3, "gmail_done", ["threadIds": (0...100).map { "t\($0)" }]),
            call(4, "gmail_done", ["threadIds": "t1"]),
            call(5, "gmail_done", ["threadIds": ["zzz"]]),
        ])
        #expect(s.result(1)["isError"] as? Bool == false, "\(s.err)")
        let draft = s.envelope(1)["data"] as? [String: Any] ?? [:]
        #expect(draft["sent"] as? Bool == false && draft["origin"] as? String == "cli" && draft["review"] as? String == "pending")
        #expect((draft["reviewLink"] as? String)?.hasPrefix("openhuman://review?") == true)
        let stored = try #require(try h.store.drafts(account: h.account, states: [], limit: 10).first)
        #expect(stored.content.bodyText == "--not an option\nline two" && stored.origin == .cli && stored.reviewState == .pending)

        #expect(s.result(2)["isError"] as? Bool == false)
        let done = s.envelope(2)["data"] as? [String: Any] ?? [:]
        #expect(done["status"] as? String == "queued")
        #expect(s.notes(2).contains("Queued locally"))
        #expect(s.errorCode(3) == -32602 && s.errorCode(4) == -32602)
        #expect(s.result(5)["isError"] as? Bool == true && (s.envelope(5)["error"] as? [String: Any])?["code"] as? String == "not_found")
        let doneOp = try #require(try h.operations([.pending]).first { $0.kind == .modifyLabels })
        #expect(doneOp.origin == .cli)

        let undo = try #require(done["undo"] as? String)
        let back = await mcp(h, [call(1, "undo", ["token": undo])])
        #expect(back.result(1)["isError"] as? Bool == false, "\(back.err)")
        #expect(try h.store.operation(doneOp.id)?.status == .cancelled)
        #expect(!(try h.operations()).contains { $0.kind == .sendDraft })
    }

    @Test func aReadOnlyServerListsAndRunsReadToolsOnly() async throws {
        let h = try Harness()
        let s = await mcp(h, [rpc(1, "tools/list"), call(2, "gmail_done", ["threadIds": ["t1"]]), call(3, "gmail_inbox")], args: ["--readonly"])
        #expect((s.result(1)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == Self.readTools)
        #expect(s.errorCode(2) == -32602)
        #expect(s.result(3)["isError"] as? Bool == false)
        #expect(try h.operations().isEmpty)
        let safe = await mcp(h, [call(1, "gmail_drafts_create", ["to": ["a@example.com"], "subject": "S", "body": "x"])], environment: [:])
        #expect(safe.errorCode(1) == -32602)
        #expect(try h.store.drafts(account: h.account, states: [], limit: 10).isEmpty)
    }
}

@Suite struct ShellCompletionTests {
    @Test func completionScriptsArePrintedForEachShell() async throws {
        let h = try Harness(seed: false)
        for shell in ["zsh", "bash", "fish"] {
            let r = await h.run(["--generate-completion-script", shell])
            #expect(r.code == 0 && r.out.contains("openhuman") && r.out.contains("gmail"), "\(shell)")
        }
    }
}
