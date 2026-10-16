import Foundation
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanCLIKit

func token(_ receipt: ActionReceipt) throws -> String {
    try JSONEncoder().encode(receipt).base64EncodedString()
}

@Suite struct UndoCommandTests {
    @Test func undoIsRefusedWhateverTheToken() async throws {
        let h = try Harness()
        let ref = try h.threadRef("t1")
        let appReceipt = try h.store.apply(.archive([try h.threadRef("t2")]), origin: .app)
        let appOp = try #require(appReceipt.operationIDs.first)
        let before = try h.operations().count
        func undo(_ text: String) async -> Run { await h.run(["gmail", "undo", text, "--json"]) }
        for action: MailAction in [.moveToInbox([ref]), .trash([ref]), .markSpam([ref]), .modifyLabels([ref], add: [GmailLabelID("Label_1")], remove: []),
                                   .createLabel(h.account, name: "X", applyTo: [ref])] {
            let r = await undo(try token(ActionReceipt(operationIDs: [], undo: action)))
            #expect(r.code == 5 && r.errorCode == "mail_changes_in_app", "\(action): \(r.code)")
        }
        let refused = await undo(try token(appReceipt))
        #expect(refused.code == 5 && refused.errorCode == "mail_changes_in_app")
        #expect(try h.store.operation(appOp)?.status == .pending)
        #expect((await undo("not-a-token")).errorCode == "mail_changes_in_app")
        let preview = await h.run(["gmail", "undo", harmlessUndoToken, "--dry-run", "--json"])
        #expect(preview.code == 0 && preview.data["dryRun"] as? Bool == true && preview.data["status"] as? String == "dry_run")
        let forbidden = await h.run(["gmail", "undo", try token(ActionReceipt(operationIDs: [], undo: .trash([ref]))), "--dry-run", "--json"])
        #expect(forbidden.code == 5 && forbidden.errorCode == "undo_not_allowed")
        #expect((await h.run(["gmail", "undo", "not-a-token", "--dry-run", "--json"])).errorCode == "bad_undo_token")
        #expect(try h.operations().count == before)
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

func mcp(_ h: Harness, _ lines: [String], args: [String] = [], environment: [String: String] = [:]) async -> McpSession {
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
    static let draftTools = ["gmail_drafts_create", "gmail_drafts_update", "gmail_drafts_reply"]
    static let triageTools = [
        "gmail_done", "gmail_archive", "gmail_move_to_inbox", "gmail_read", "gmail_unread", "gmail_star", "gmail_unstar", "gmail_snooze",
        "gmail_unsnooze", "gmail_remind", "gmail_unremind", "undo", "gmail_undo",
    ]
    static let notExposed: Set<String> = [
        "gmail.send", "gmail.reply", "gmail.reply-all", "gmail.forward", "gmail.drafts.send", "gmail.trash", "gmail.untrash", "gmail.spam",
        "gmail.not-spam", "gmail.thread.modify", "gmail.batch.modify", "gmail.labels.create", "gmail.splits.create", "gmail.splits.update",
        "gmail.splits.delete", "gmail.splits.reorder", "gmail.drafts.delete", "gmail.drafts.forward", "gmail.review.approve",
        "gmail.review.reject", "accounts.add", "accounts.remove", "auth.login", "auth.logout", "config.set", "sync.run", "gmail.history",
        "gmail.attachments.get", "calendar.events", "gmail.snippets.add", "gmail.snippets.delete", "gmail.snippets.import",
        "gmail.done", "gmail.move-to-inbox", "gmail.read", "gmail.unread", "gmail.star", "gmail.unstar", "gmail.snooze", "gmail.unsnooze",
        "gmail.remind", "gmail.unremind", "gmail.undo",
    ]

    func listed(_ h: Harness, _ args: [String] = [], environment: [String: String] = [:]) async -> [String] {
        let r = await h.run(["mcp", "--list-tools", "--json"] + args, environment: environment)
        return r.list("tools").compactMap { $0["name"] as? String }
    }

    @Test func theToolListIsPinnedAndHasNoSendTool() async throws {
        let h = try Harness()
        #expect(await listed(h) == Self.readTools + Self.draftTools)
        #expect(await listed(h, ["--readonly"]) == Self.readTools)
        #expect(await listed(h, environment: ["OPENHUMAN_READONLY": "1"]) == Self.readTools)
        for tool in McpTools.all {
            let meta = try #require(CommandCatalog.meta(for: tool.path), "\(tool.name)")
            #expect(meta.implemented && meta.reserved == nil && !meta.network, "\(tool.name)")
            #expect(!Self.notExposed.contains(meta.path), "\(tool.name) runs \(meta.path)")
            #expect(tool.group == .read ? meta.writes == .none : meta.writes == .agentDraft, "\(tool.name)")
            #expect(!tool.name.contains("send") && tool.name.allSatisfy { $0.isLowercase || $0 == "_" }, "\(tool.name)")
        }
        try h.store.setSetting(.cliReadonlyDefault, true, scope: .global)
        #expect(await listed(h) == Self.readTools)
        try h.store.setSetting(.cliReadonlyDefault, false, scope: .global)
        try h.store.setSetting(.cliAllowedCommands, ["mcp", "gmail.search", "gmail.drafts.show"], scope: .global)
        #expect(await listed(h) == ["gmail_search", "gmail_drafts_get"])
        try h.store.setSetting(.cliAllowedCommands, ["gmail.search"], scope: .global)
        let refused = await mcp(h, [rpc(1, "initialize", ["protocolVersion": "2025-06-18"])])
        #expect(refused.code == 5 && refused.stdout.isEmpty && refused.err.contains("command_not_allowed"))
    }

    @Test func theToolListHasNoTriageTools() async throws {
        let h = try Harness()
        #expect(!McpTools.all.contains { CommandCatalog.meta(for: $0.path)?.writes == .mailChange })
        #expect(Set(McpTools.all.map(\.name)).isDisjoint(with: Self.triageTools))
        try h.store.setSetting(.cliAllowedCommands, ["mcp", "gmail.done", "gmail.archive", "gmail.undo", "gmail.snooze"], scope: .global)
        #expect(await listed(h).isEmpty)
        try h.store.setSetting(.cliAllowedCommands, nil, scope: .global)
        let before = try Snapshot(h)
        let s = await mcp(h, [rpc(1, "tools/list")] + Self.triageTools.enumerated().map { call($0.offset + 2, $0.element, ["threadIds": ["t1"]]) })
        let names = (s.result(1)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(names == Self.readTools + Self.draftTools)
        for index in Self.triageTools.indices { #expect(s.errorCode(index + 2) == -32602, "\(Self.triageTools[index])") }
        #expect(!s.err.contains("mcp: tool gmail_"))
        #expect(try Snapshot(h) == before && h.operations().isEmpty)
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
        #expect(tools.compactMap { $0["name"] as? String } == Self.readTools + Self.draftTools)
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

    @Test func draftToolsGoThroughThePolicy() async throws {
        let h = try Harness()
        let s = await mcp(h, [
            call(1, "gmail_drafts_create", ["to": ["a@example.com"], "subject": "Hi", "body": "--not an option\nline two", "note": "check"]),
            call(2, "gmail_drafts_reply", ["messageId": "m1", "body": "Thanks"]),
            call(3, "gmail_drafts_create", ["to": "a@example.com", "subject": "Hi", "body": "x"]),
            call(4, "gmail_drafts_reply", ["messageId": "zzz", "body": "x"]),
        ])
        #expect(s.result(1)["isError"] as? Bool == false, "\(s.err)")
        let draft = s.envelope(1)["data"] as? [String: Any] ?? [:]
        #expect(draft["sent"] as? Bool == false && draft["origin"] as? String == "cli" && draft["review"] as? String == "pending")
        #expect(draft["status"] as? String == "queued")
        #expect((draft["reviewLink"] as? String)?.hasPrefix("openhuman://review?") == true)
        let stored = try #require(try h.store.drafts(account: h.account, states: [], limit: 10).first { $0.composeMode == .new })
        #expect(stored.content.bodyText == "--not an option\nline two" && stored.origin == .cli && stored.reviewState == .pending)

        #expect(s.result(2)["isError"] as? Bool == false, "\(s.err)")
        #expect(s.notes(2).contains("Saved locally"))
        #expect(s.errorCode(3) == -32602)
        #expect(s.result(4)["isError"] as? Bool == true && (s.envelope(4)["error"] as? [String: Any])?["code"] as? String == "not_found")
        let ops = try h.operations()
        #expect(ops.count == 2 && ops.allSatisfy { $0.kind == .upsertDraft && $0.origin == .cli })
    }

    @Test func aReadOnlyServerListsAndRunsReadToolsOnly() async throws {
        let h = try Harness()
        let s = await mcp(h, [rpc(1, "tools/list"), call(2, "gmail_drafts_create", ["to": ["a@example.com"], "subject": "S", "body": "x"]),
                              call(3, "gmail_inbox")], args: ["--readonly"])
        #expect((s.result(1)["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == Self.readTools)
        #expect(s.errorCode(2) == -32602)
        #expect(s.result(3)["isError"] as? Bool == false)
        let viaEnv = await mcp(h, [call(1, "gmail_drafts_create", ["to": ["a@example.com"], "subject": "S", "body": "x"])],
                               environment: ["OPENHUMAN_READONLY": "1"])
        #expect(viaEnv.errorCode(1) == -32602)
        #expect(try h.operations().isEmpty)
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
