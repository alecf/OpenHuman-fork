import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanLinks
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanCLIKit

@Suite struct TriageRefusalTests {
    @Test func everyTriageVerbAndAliasIsRefusedAndChangesNothing() async throws {
        let h = try Harness()
        let before = try Snapshot(h)
        let undoToken = try JSONEncoder().encode(ActionReceipt(operationIDs: [], undo: .moveToInbox([try h.threadRef("t1")]))).base64EncodedString()
        for args in [["done", "t1"], ["archive", "t1", "t2"], ["move-to-inbox", "t2"], ["unarchive", "t2"], ["read", "t1"], ["unread", "t2"],
                     ["star", "t2"], ["unstar", "t3"], ["snooze", "t1", "--until", "tomorrow 9am"], ["unsnooze", "t1"],
                     ["remind", "t1", "--at", "+2h", "--if-no-reply"], ["unremind", "t1"], ["undo", undoToken]] {
            let r = await h.run(["gmail"] + args + ["--json"])
            #expect(r.code == 5 && r.errorCode == "mail_changes_in_app", "\(args.prefix(1)): \(r.code) \(r.err)")
            #expect(r.err.contains("Make mail changes in OpenHuman Mail."))
        }
        let alias = await h.run(["gmail", "archive", "t3", "--json"])
        #expect(alias.code == 5 && alias.json["command"] as? String == "gmail.done")
        #expect(try Snapshot(h) == before)
        #expect(try h.operations().isEmpty && h.store.activeReminders(account: h.account, limit: 10).isEmpty)
        let inbox = await h.run(["gmail", "inbox", "--json"])
        #expect(inbox.list("threads").compactMap { $0["threadId"] as? String } == ["t1", "t3", "t2"])
    }

    @Test func aDryRunPreviewsTheChangeAndQueuesNothing() async throws {
        let h = try Harness()
        let before = try Snapshot(h)
        let r = await h.run(["gmail", "done", "t1", "t2", "--dry-run", "--json"])
        #expect(r.code == 0, "\(r.code) \(r.err)")
        #expect(r.data["verb"] as? String == "done" && r.data["dryRun"] as? Bool == true && r.data["status"] as? String == "dry_run")
        #expect((r.data["operationIds"] as? [Any])?.isEmpty == true)
        let threads = r.data["threads"] as? [[String: Any]] ?? []
        #expect(threads.compactMap { $0["threadId"] as? String } == ["t1", "t2"])
        #expect(threads.allSatisfy {
            $0["account"] as? String == "me@example.com" && ($0["link"] as? String)?.hasPrefix("openhuman://thread/me@example.com/") == true
        })
        #expect(r.err.contains("Without --dry-run this command exits 5 mail_changes_in_app"))
        let remind = await h.run(["gmail", "remind", "t1", "--at", "+2h", "--dry-run", "--json"])
        #expect(remind.code == 0 && remind.data["verb"] as? String == "remind")
        #expect(remind.data["note"] as? String == "Reminders are kept on this Mac only.")
        let alias = await h.run(["gmail", "archive", "t3", "--dry-run", "--json"])
        #expect(alias.code == 0 && alias.json["command"] as? String == "gmail.done")
        #expect((await h.run(["gmail", "snooze", "t1", "--until", "nonsense", "--dry-run", "--json"])).errorCode == "bad_date")
        #expect((await h.run(["gmail", "star", "zzz", "--dry-run", "--json"])).code == 3)
        #expect((await h.run(["gmail", "read", "bad id!", "--dry-run", "--json"])).errorCode == "bad_id")
        let undo = try JSONEncoder().encode(ActionReceipt(operationIDs: [], undo: .moveToInbox([try h.threadRef("t1")]))).base64EncodedString()
        let undoPreview = await h.run(["gmail", "undo", undo, "--dry-run", "--json"])
        #expect(undoPreview.code == 0 && undoPreview.data["status"] as? String == "dry_run")
        #expect(undoPreview.data["threadIds"] as? [String] == ["t1"])
        #expect(try Snapshot(h) == before)
        #expect(try h.operations().isEmpty && h.store.activeReminders(account: h.account, limit: 10).isEmpty)
    }
}

@Suite struct DraftSettleTests {
    typealias Settled = (status: String, exit: CLIStatus, notes: [String])

    func settle(_ h: Harness, appRunning: Bool = true, _ finish: (OperationItem) throws -> Void) async throws -> Settled {
        if appRunning {
            _ = try h.store.acquireLease(account: h.account, ownerID: "test-app", kind: "app", pid: ProcessInfo.processInfo.processIdentifier,
                                         host: ProcessIdentity.localHostName, now: Date(), ttl: .seconds(3600))
        }
        let created = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x", "--no-wait", "--json"])
        #expect(created.code == 6, "\(created.code) \(created.err)")
        let op = try #require(try h.operations([.pending]).first)
        try finish(op)
        let env = CLIEnvironment(variables: h.allowedEnvironment, stdout: BufferSink(), stderr: BufferSink(), stdoutIsTTY: false,
                                 stdinIsTTY: false, clock: h.clock)
        let ctx = try CLIContext(env: env, global: try GlobalOptions.parse(["--timeout", "0s"]), path: "gmail.drafts.create",
                                 meta: try #require(CommandCatalog.meta(for: "gmail.drafts.create")))
        defer { ctx.close() }
        let account = try #require(try h.store.accounts().first)
        return await DraftSupport.settle(ctx, engine: try ctx.engine(), accounts: [account], ids: [op.id], wait: true,
                                         note: DraftSupport.queuedNote)
    }

    @Test func waitingForTheAppExit0WhenItDrainsAnd6WhenItDoesNot() async throws {
        let h = try Harness()
        let applied = try await settle(h) { op in
            guard case let .upsertDraft(_, version) = op.payload else { Issue.record("not a draft upload"); return }
            try h.store.complete(op.id, outcome: .draftSaved(gmailDraftID: GmailDraftID("r1"), gmailMessageID: GmailMessageID("dm1"), version: version))
        }
        #expect(applied.status == "succeeded" && applied.exit == .ok && applied.notes.isEmpty)
        let slow = try await settle(try Harness()) { _ in }
        #expect(slow.status == "queued" && slow.exit == .queued && slow.notes == ["Queued; the app has not confirmed it within the timeout."])
        let noApp = try await settle(try Harness(), appRunning: false) { _ in }
        #expect(noApp.status == "queued" && noApp.exit == .queued && noApp.notes == [DraftSupport.queuedNote])
    }

    @Test func aFailedOperationIsAFailureNotQueued() async throws {
        let h = try Harness()
        let r = try await settle(h) { try h.store.fail($0.id, code: "boom", message: "boom", retryAt: nil) }
        #expect(r.status == "failed" && r.exit == .failure)
    }

    @Test func anOperationTheAppRefusedIsPolicyBlocked() async throws {
        let h = try Harness()
        let r = try await settle(h) { try h.store.fail($0.id, code: "not_applied_outside_app", message: "queued outside the app", retryAt: nil) }
        #expect(r.status == "refused" && r.exit == .policyBlocked)
        #expect(r.notes.first?.contains("until you review them") == true)
    }
}

@Suite struct DraftWriteTests {
    func draftRow(_ h: Harness) throws -> DraftListItem {
        try #require(try h.store.drafts(account: h.account, states: [], limit: 50).first)
    }

    @Test func createMakesAPendingCliDraftWithAReviewLinkAndNeverSends() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "create", "--to", "alice@example.com", "--to", "Bob Jones <bob@example.com>",
                             "--cc", "carol@example.com", "--bcc", "secret@example.com", "--subject", "Hello", "--note", "check the tone",
                             "--body", "-", "--json"], stdin: "line one\nline <two> & three")
        #expect(r.code == 6)
        #expect(r.data["sent"] as? Bool == false)
        #expect(r.data["origin"] as? String == "cli" && r.data["review"] as? String == "pending" && r.data["state"] as? String == "editing")
        let draft = try draftRow(h)
        #expect(r.data["draftId"] as? String == draft.id.rawValue)
        #expect(draft.origin == .cli && draft.reviewState == .pending && draft.agentNote == "check the tone")
        #expect(draft.content.to.map(\.email) == ["alice@example.com", "bob@example.com"] && draft.content.to[1].name == "Bob Jones")
        #expect(draft.content.bcc.map(\.email) == ["secret@example.com"])
        #expect(draft.content.bodyHTML == "<div dir=\"ltr\">line one<br>\nline &lt;two&gt; &amp; three</div>")
        let expectedLink = MailLinkBuilder.url(for: .review([DraftRef(account: AccountRef("me@example.com"), draftID: draft.id.rawValue)])).absoluteString
        #expect(r.data["reviewLink"] as? String == expectedLink)
        #expect(expectedLink.hasPrefix("openhuman://review?account=me@example.com&ids="))
        #expect(r.data["link"] as? String == "openhuman://draft/me@example.com/\(draft.id.rawValue)")
        let kinds = try h.operations().map(\.kind)
        #expect(kinds == [.upsertDraft])
        #expect(!kinds.contains(.sendDraft))
        #expect(r.err.contains("Saved locally. OpenHuman Mail uploads an agent draft to Gmail only after you approve it there."))
        let review = await h.run(["gmail", "review", "list", "--json"])
        #expect(review.list("drafts").count == 1 && review.data["reviewLink"] as? String == expectedLink)
        let pending = await h.run(["gmail", "drafts", "list", "--review", "pending", "--origin", "cli", "--json"])
        #expect(pending.list("drafts").count == 1)
        #expect((await h.run(["gmail", "drafts", "list", "--origin", "user", "--json"])).list("drafts").isEmpty)
        let got = await h.run(["gmail", "drafts", "get", draft.id.rawValue, "--json"])
        #expect(got.code == 0 && got.data["subject"] as? String == "Hello")
        #expect((await h.run(["gmail", "drafts", "get", "nope", "--json"])).code == 3)
        #expect((await h.run(["gmail", "counts", "--json"])).list("counts").first?["pendingReview"] as? Int == 1)
    }

    @Test func bodyFromAFileAndInputValidation() async throws {
        let h = try Harness()
        let file = h.directory.appendingPathComponent("body.txt")
        try FileManager.default.createDirectory(at: h.directory, withIntermediateDirectories: true)
        try "From a file".write(to: file, atomically: true, encoding: .utf8)
        let ok = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body-file", file.path, "--json"])
        #expect(ok.code == 6)
        #expect(try draftRow(h).content.bodyText == "From a file")
        let before = try h.store.drafts(account: h.account, states: [], limit: 50).count
        func create(_ extra: [String]) async -> Run {
            await h.run(["gmail", "drafts", "create"] + extra + ["--json"])
        }
        #expect((await create(["--subject", "S", "--body", "x"])).errorCode == "recipient_required")
        #expect((await create(["--to", "a@example.com", "--subject", "S"])).errorCode == "body_required")
        #expect((await create(["--to", "not-an-address", "--subject", "S", "--body", "x"])).errorCode == "bad_address")
        #expect((await create(["--to", "a@example.com\nBcc: x@example.com", "--subject", "S", "--body", "x"])).errorCode == "bad_address")
        #expect((await create(["--to", "a@example.com", "--subject", "S\nBcc: x@example.com", "--body", "x"])).errorCode == "bad_subject")
        #expect((await create(["--to", "a@example.com", "--subject", "S", "--body", "x", "--body-file", file.path])).errorCode == "body_conflict")
        #expect((await create(["--to", "a@example.com", "--subject", "S", "--body-file", "/nonexistent/file"])).errorCode == "bad_body_file")
        #expect(try h.store.drafts(account: h.account, states: [], limit: 50).count == before)
    }

    @Test func dryRunShowsTheEnvelopeBccSeparatelyAndWritesNothing() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--bcc", "hidden@example.com", "--subject", "S",
                             "--body", "hi", "--dry-run", "--json"])
        #expect(r.code == 0 && r.data["dryRun"] as? Bool == true && r.data["sent"] as? Bool == false)
        #expect(r.data["bcc"] == nil)
        #expect((r.data["envelopeBcc"] as? [[String: Any]])?.first?["email"] as? String == "hidden@example.com")
        #expect(try h.store.drafts(account: h.account, states: [], limit: 50).isEmpty && h.operations().isEmpty)
    }

    @Test func replyBuildsTheSkeletonFromTheStoredMessage() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "reply", "m1", "--body", "Thanks!", "--note", "n", "--json"])
        #expect(r.code == 6)
        let draft = try draftRow(h)
        #expect(draft.composeMode == .reply && draft.origin == .cli && draft.reviewState == .pending)
        #expect(draft.content.to.map(\.email) == ["alice@example.com"])
        #expect(draft.content.subject == "Re: Invoice for October")
        #expect(draft.content.bodyHTML.hasPrefix("<div dir=\"ltr\">Thanks!</div>") && draft.content.bodyHTML.contains("gmail_quote"))
        #expect(draft.thread?.gmailThreadID.rawValue == "t1")
        #expect(r.data["threadId"] as? String == "t1")
        let all = await h.run(["gmail", "drafts", "reply", "m2", "--all", "--body", "ok", "--json"])
        #expect(all.code == 6 && all.data["mode"] as? String == "reply_all")
        #expect((await h.run(["gmail", "drafts", "reply", "nope", "--body", "x", "--json"])).code == 3)
        #expect(try h.operations().allSatisfy { $0.kind == .upsertDraft })
    }

    @Test func updateReplacesAgentDraftsOnlyAndReturnsThemToReview() async throws {
        let h = try Harness()
        _ = await h.run(["gmail", "drafts", "reply", "m1", "--body", "First", "--json"])
        let draft = try draftRow(h)
        try h.store.setReviewState(draft.id, .approved)
        let r = await h.run(["gmail", "drafts", "update", draft.id.rawValue, "--body", "Second", "--note", "revised", "--json"])
        #expect(r.code == 6)
        let updated = try #require(try h.store.draft(draft.id))
        #expect(updated.reviewState == .pending && updated.agentNote == "revised")
        #expect(updated.content.bodyHTML.hasPrefix("<div dir=\"ltr\">Second</div>") && updated.content.bodyHTML.contains("gmail_quote"))
        #expect(updated.content.to.map(\.email) == ["alice@example.com"])
        let own = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                          content: DraftContent(to: [], cc: [], bcc: [], subject: "mine", bodyHTML: "<div>x</div>", attachments: []),
                                          origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        let refused = await h.run(["gmail", "drafts", "update", own.rawValue, "--body", "x", "--json"])
        #expect(refused.code == 5 && refused.errorCode == "not_agent_draft")
        #expect(try #require(try h.store.draft(own)).content.bodyHTML == "<div>x</div>")
        #expect((await h.run(["gmail", "drafts", "update", "nope", "--body", "x", "--json"])).code == 3)
    }

    @Test func anAccountWithoutTheModifyGrantMustBeReauthorizedToDraft() async throws {
        let h = try Harness(scopes: [GmailScope.readonly])
        let r = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x", "--json"])
        #expect(r.code == 4 && r.errorCode == "auth_required")
        #expect(try h.operations().isEmpty && h.store.drafts(account: h.account, states: [], limit: 50).isEmpty)
    }

    @Test func noCliCommandEverCreatesASendOperation() async throws {
        let h = try Harness()
        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: "S",
                                                                  bodyHTML: "<div>hi</div>", attachments: []),
                                            origin: .cli, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        for meta in CommandCatalog.entries {
            var args = commandArguments(meta.path, draftID: draft.rawValue)
            if meta.confirm { args.append("--yes") }
            if meta.path == "config.set" { continue }
            _ = await h.run(args + ["--json"])
        }
        _ = await h.run(["gmail", "send", "--to", "a@example.com"])
        _ = await h.run(["gmail", "drafts", "send", draft.rawValue])
        let ops = try h.operations()
        #expect(ops.count >= 3 && ops.contains { $0.kind == .upsertDraft })
        #expect(!ops.contains { $0.kind == .sendDraft })
        #expect(try h.store.drafts(account: h.account, states: [.sending, .sent, .scheduled], limit: 50).isEmpty)
    }

    @Test func aLocalClientEngineCannotSend() async throws {
        let h = try Harness()
        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: "S",
                                                                  bodyHTML: "<div>hi</div>", attachments: []),
                                            origin: .cli, reviewState: .approved, agentNote: nil, extraHeaders: [:])
        let engine = MailEngine(store: h.store, gmailFactory: nil, tokenStore: nil, oauthClient: nil,
                                configuration: EngineConfiguration(role: .localClient, appVersion: "t", gmail: GmailClientConfig(userAgent: "t"),
                                                                   clock: h.clock), systemEvents: nil)
        await #expect(throws: EngineError.sendNotAllowed) { _ = try await engine.send(draft, authorization: .userConfirmed, undoWindow: nil) }
        await #expect(throws: EngineError.sendNotAllowed) { _ = try await engine.scheduleSend(draft, at: Date().addingTimeInterval(3600)) }
        #expect(try h.operations().isEmpty)
    }

    @Test func cliSourcesHaveNoSendPathOrTokenAccess() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 15)
        let forbidden = ["engine.send(", "sendNow", "scheduleSend", "SendAuthorization", "userConfirmed", "TokenStore", "GmailClientFactory",
                         "OpenHumanGmailApple", "KeychainTokenStore", "OAuthClientConfig", "URLSession"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                #expect(!text.contains(token), "\(file.lastPathComponent) mentions \(token)")
            }
        }
    }
}
