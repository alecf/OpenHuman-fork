import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanLinks
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanCLIKit

func modifyOps(_ h: Harness) throws -> [(add: [String], remove: [String], names: [String], ids: [String])] {
    try h.operations().compactMap { op in
        guard case let .modifyLabels(ids, add, remove, names) = op.payload else { return nil }
        return (add.map(\.rawValue).sorted(), remove.map(\.rawValue).sorted(), names.sorted(), ids.map(\.rawValue).sorted())
    }
}

@Suite struct TriageWriteTests {
    static let env = Harness.write

    @Test func doneAndItsAliasQueueTheInboxRemovalAndExit6WithoutTheApp() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "done", "t1", "--json"], environment: Self.env)
        #expect(r.code == 6)
        #expect(r.json["ok"] as? Bool == true)
        #expect(r.data["status"] as? String == "queued")
        #expect(r.data["undo"] as? String != nil)
        #expect(r.err.contains("Queued locally. OpenHuman Mail applies changes queued by the CLI to Gmail only in a guarded test run"))
        let ops = try modifyOps(h)
        #expect(ops.count == 1 && ops[0].remove == ["INBOX"] && ops[0].add.isEmpty && ops[0].ids == ["m1", "m2"])
        let alias = await h.run(["gmail", "archive", "t3", "--json"], environment: Self.env)
        #expect(alias.code == 6 && alias.json["command"] as? String == "gmail.done")
        #expect(try modifyOps(h).count == 2)
        let inbox = await h.run(["gmail", "inbox", "--json"])
        #expect(inbox.list("threads").compactMap { $0["threadId"] as? String } == ["t2"])
    }

    @Test func eachTriageVerbQueuesItsOps() async throws {
        let h = try Harness()
        func ops(_ args: [String]) async throws -> (code: Int32, ops: [(add: [String], remove: [String], names: [String], ids: [String])]) {
            let before = try modifyOps(h).count
            let r = await h.run(["gmail"] + args + ["--json"], environment: Self.env)
            return (r.code, Array(try modifyOps(h).dropFirst(before)))
        }
        let read = try await ops(["read", "t1"])
        #expect(read.code == 6 && read.ops.count == 1 && read.ops[0].remove == ["UNREAD"])
        let unread = try await ops(["unread", "t2"])
        #expect(unread.code == 6 && unread.ops.count == 1 && unread.ops[0].add == ["UNREAD"])
        let star = try await ops(["star", "t2"])
        #expect(star.code == 6 && star.ops.count == 1 && star.ops[0].add == ["STARRED"])
        let unstar = try await ops(["unstar", "t3"])
        #expect(unstar.code == 6 && unstar.ops.count == 1 && unstar.ops[0].remove == ["STARRED"])
        let done = try await ops(["done", "t2"])
        #expect(done.ops.count == 1 && done.ops[0].remove == ["INBOX"])
        let back = try await ops(["move-to-inbox", "t2"])
        #expect(back.code == 6 && back.ops.count == 1 && back.ops[0].add == ["INBOX"])
        let unarchive = try await ops(["unarchive", "t2"])
        #expect(unarchive.ops.isEmpty)
        let kinds = try h.operations().map(\.kind)
        #expect(!kinds.contains(.sendDraft))
    }

    @Test func manyThreadsAreOneActionAndUnknownIdsChangeNothing() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "done", "t1", "t2", "--json"], environment: Self.env)
        #expect(r.code == 6 && (r.data["threads"] as? [[String: Any]])?.count == 2)
        let before = try h.operations().count
        let missing = await h.run(["gmail", "done", "t3", "zzz", "--json"], environment: Self.env)
        #expect(missing.code == 3 && missing.errorCode == "not_found")
        #expect((missing.error["details"] as? [String: Any])?["ids"] as? [String] == ["zzz"])
        #expect(try h.operations().count == before)
        #expect((await h.run(["gmail", "done", "bad id!", "--json"], environment: Self.env)).code == 2)
        #expect((await h.run(["gmail", "done", "--json"], environment: Self.env)).code == 2)
    }

    @Test func dryRunPrintsThePlanAndWritesNothing() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "done", "t1", "--dry-run", "--json"], environment: Self.env)
        #expect(r.code == 0 && r.data["dryRun"] as? Bool == true && r.data["status"] as? String == "dry_run")
        #expect(try h.operations().isEmpty)
    }

    @Test func waitingForTheAppExit0WhenItDrainsAnd6WhenItDoesNot() async throws {
        let h = try Harness()
        try h.holdLease()
        let drainer = Task.detached { [store = h.store, account = h.account] in
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !Task.isCancelled {
                for op in (try? store.claimReadyOperations(account: account, now: Date(), limit: 10, ownerID: "test-app")) ?? [] {
                    try? store.complete(op.id, outcome: .labelsApplied)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { drainer.cancel() }
        let applied = await h.run(["gmail", "done", "t1", "--timeout", "20s", "--json"], environment: Self.env)
        #expect(applied.code == 0 && applied.data["status"] as? String == "succeeded")
        drainer.cancel()
        _ = await drainer.value
        let slow = await h.run(["gmail", "done", "t2", "--timeout", "500ms", "--json"], environment: Self.env)
        #expect(slow.code == 6 && slow.data["status"] as? String == "queued")
        #expect(!slow.err.contains("not running"))
        let noWait = await h.run(["gmail", "done", "t3", "--no-wait", "--json"], environment: Self.env)
        #expect(noWait.code == 6)
        #expect(try h.operations([.pending]).count == 2)
    }

    @Test func aFailedOperationIsAFailureNotQueued() async throws {
        let h = try Harness()
        try h.holdLease()
        let failer = Task.detached { [store = h.store, account = h.account] in
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !Task.isCancelled {
                for op in (try? store.claimReadyOperations(account: account, now: Date(), limit: 10, ownerID: "test-app")) ?? [] {
                    try? store.fail(op.id, code: "boom", message: "boom", retryAt: nil)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { failer.cancel() }
        let r = await h.run(["gmail", "done", "t1", "--timeout", "20s", "--json"], environment: Self.env)
        #expect(r.code == 1 && r.data["status"] as? String == "failed")
    }

    @Test func anOperationTheAppRefusedIsPolicyBlocked() async throws {
        let h = try Harness()
        try h.holdLease()
        let refuser = Task.detached { [store = h.store, account = h.account] in
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !Task.isCancelled {
                for op in (try? store.claimReadyOperations(account: account, now: Date(), limit: 10, ownerID: "test-app")) ?? [] {
                    try? store.fail(op.id, code: "safe_mode_blocked", message: "queued outside the app", retryAt: nil)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { refuser.cancel() }
        let r = await h.run(["gmail", "done", "t1", "--timeout", "20s", "--json"], environment: Self.env)
        #expect(r.code == 5 && r.data["status"] as? String == "refused")
    }

    @Test func snoozeQueuesTheStampLabelInUTCAndReschedules() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "snooze", "t1", "--until", "tomorrow 9am", "--json"], environment: Self.env, timeZone: "Europe/Berlin")
        #expect(r.code == 6)
        let snoozeOps = try modifyOps(h).filter { $0.names.contains { $0.hasPrefix("OpenHuman/Snoozed/") } }
        #expect(snoozeOps.count == 1)
        #expect(snoozeOps[0].names.contains("OpenHuman/Snoozed/20261011T0700Z"))
        #expect(snoozeOps[0].remove.contains("INBOX"))
        let first = await h.run(["gmail", "list", "--view", "snoozed", "--json"])
        #expect(first.list("threads").first?["snoozedUntil"] as? String == "2026-10-11T07:00:00Z")
        let again = await h.run(["gmail", "snooze", "t1", "--until", "+2h", "--json"], environment: Self.env, timeZone: "Europe/Berlin")
        #expect(again.code == 6)
        let all = try modifyOps(h).filter { $0.names.contains { $0.hasPrefix("OpenHuman/Snoozed/") } }
        #expect(all.count == 2 && all[1].names.contains("OpenHuman/Snoozed/20261010T1858Z"))
        let moved = await h.run(["gmail", "list", "--view", "snoozed", "--json"])
        #expect(moved.list("threads").first?["snoozedUntil"] as? String == "2026-10-10T18:58:00Z")
        let before = try h.operations().count
        let past = await h.run(["gmail", "snooze", "t1", "--until", "2026-01-01T09:00:00Z", "--json"], environment: Self.env)
        #expect(past.code == 2 && past.errorCode == "time_in_past")
        #expect((await h.run(["gmail", "snooze", "t1", "--until", "someday", "--json"], environment: Self.env)).errorCode == "bad_date")
        #expect(try h.operations().count == before)
        let wake = await h.run(["gmail", "unsnooze", "t1", "--json"], environment: Self.env)
        #expect(wake.code == 0 && (wake.data["operationIds"] as? [Any])?.isEmpty == true)
        #expect((await h.run(["gmail", "list", "--view", "snoozed", "--json"])).list("threads").isEmpty)
    }

    @Test func remindWritesOnlyAReminderRow() async throws {
        let h = try Harness()
        let before = try h.operations().count
        let r = await h.run(["gmail", "remind", "t1", "--at", "+2h", "--if-no-reply", "--json"], environment: Self.env)
        #expect(r.code == 0 && r.data["status"] as? String == "succeeded")
        #expect(r.data["note"] as? String == "Reminders are kept on this Mac only.")
        #expect(try h.operations().count == before)
        let reminders = try h.store.activeReminders(account: h.account, limit: 10)
        #expect(reminders.count == 1 && reminders[0].reminder.condition == .ifNoReply)
        #expect(reminders[0].reminder.dueAt == fixedNow.addingTimeInterval(7200))
        let thread = await h.run(["gmail", "thread", "get", "t1", "--json"])
        #expect((thread.data["reminder"] as? [String: Any])?["condition"] as? String == "if_no_reply")
        _ = await h.run(["gmail", "remind", "t1", "--at", "+4h", "--json"], environment: Self.env)
        #expect(try h.store.activeReminders(account: h.account, limit: 10).count == 1)
        let gone = await h.run(["gmail", "unremind", "t1", "--json"], environment: Self.env)
        #expect(gone.code == 0)
        #expect(try h.store.activeReminders(account: h.account, limit: 10).isEmpty)
        #expect(try h.operations().count == before)
    }

    @Test func accountsWithoutTheModifyGrantAreReadOnlyWhateverTheMode() async throws {
        let h = try Harness(scopes: [GmailScope.readonly])
        let r = await h.run(["gmail", "done", "t1", "--json"], environment: Self.env)
        #expect(r.code == 5 && r.errorCode == "blocked_by_safe_mode")
        #expect(try h.operations().isEmpty)
    }
}

@Suite struct DraftWriteTests {
    static let env = Harness.write

    func draftRow(_ h: Harness) throws -> DraftListItem {
        try #require(try h.store.drafts(account: h.account, states: [], limit: 50).first)
    }

    @Test func createMakesAPendingCliDraftWithAReviewLinkAndNeverSends() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "create", "--to", "alice@example.com", "--to", "Bob Jones <bob@example.com>",
                             "--cc", "carol@example.com", "--bcc", "secret@example.com", "--subject", "Hello", "--note", "check the tone",
                             "--body", "-", "--json"], environment: Self.env, stdin: "line one\nline <two> & three")
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
        let ok = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body-file", file.path, "--json"], environment: Self.env)
        #expect(ok.code == 6)
        #expect(try draftRow(h).content.bodyText == "From a file")
        let before = try h.store.drafts(account: h.account, states: [], limit: 50).count
        func create(_ extra: [String]) async -> Run {
            await h.run(["gmail", "drafts", "create"] + extra + ["--json"], environment: Self.env)
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
                             "--body", "hi", "--dry-run", "--json"], environment: Self.env)
        #expect(r.code == 0 && r.data["dryRun"] as? Bool == true && r.data["sent"] as? Bool == false)
        #expect(r.data["bcc"] == nil)
        #expect((r.data["envelopeBcc"] as? [[String: Any]])?.first?["email"] as? String == "hidden@example.com")
        #expect(try h.store.drafts(account: h.account, states: [], limit: 50).isEmpty && h.operations().isEmpty)
    }

    @Test func replyBuildsTheSkeletonFromTheStoredMessage() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "reply", "m1", "--body", "Thanks!", "--note", "n", "--json"], environment: Self.env)
        #expect(r.code == 6)
        let draft = try draftRow(h)
        #expect(draft.composeMode == .reply && draft.origin == .cli && draft.reviewState == .pending)
        #expect(draft.content.to.map(\.email) == ["alice@example.com"])
        #expect(draft.content.subject == "Re: Invoice for October")
        #expect(draft.content.bodyHTML.hasPrefix("<div dir=\"ltr\">Thanks!</div>") && draft.content.bodyHTML.contains("gmail_quote"))
        #expect(draft.thread?.gmailThreadID.rawValue == "t1")
        #expect(r.data["threadId"] as? String == "t1")
        let all = await h.run(["gmail", "drafts", "reply", "m2", "--all", "--body", "ok", "--json"], environment: Self.env)
        #expect(all.code == 6 && all.data["mode"] as? String == "reply_all")
        #expect((await h.run(["gmail", "drafts", "reply", "nope", "--body", "x", "--json"], environment: Self.env)).code == 3)
        #expect(try h.operations().allSatisfy { $0.kind == .upsertDraft })
    }

    @Test func updateReplacesAgentDraftsOnlyAndReturnsThemToReview() async throws {
        let h = try Harness()
        _ = await h.run(["gmail", "drafts", "reply", "m1", "--body", "First", "--json"], environment: Self.env)
        let draft = try draftRow(h)
        try h.store.setReviewState(draft.id, .approved)
        let r = await h.run(["gmail", "drafts", "update", draft.id.rawValue, "--body", "Second", "--note", "revised", "--json"], environment: Self.env)
        #expect(r.code == 6)
        let updated = try #require(try h.store.draft(draft.id))
        #expect(updated.reviewState == .pending && updated.agentNote == "revised")
        #expect(updated.content.bodyHTML.hasPrefix("<div dir=\"ltr\">Second</div>") && updated.content.bodyHTML.contains("gmail_quote"))
        #expect(updated.content.to.map(\.email) == ["alice@example.com"])
        let own = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                          content: DraftContent(to: [], cc: [], bcc: [], subject: "mine", bodyHTML: "<div>x</div>", attachments: []),
                                          origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        let refused = await h.run(["gmail", "drafts", "update", own.rawValue, "--body", "x", "--json"], environment: Self.env)
        #expect(refused.code == 5 && refused.errorCode == "not_agent_draft")
        #expect(try #require(try h.store.draft(own)).content.bodyHTML == "<div>x</div>")
        #expect((await h.run(["gmail", "drafts", "update", "nope", "--body", "x", "--json"], environment: Self.env)).code == 3)
    }

    @Test func draftsAreRefusedInReadOnlySafeMode() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x", "--json"])
        #expect(r.code == 5 && r.errorCode == "blocked_by_safe_mode")
        #expect(try h.store.drafts(account: h.account, states: [], limit: 50).isEmpty && h.operations().isEmpty)
    }

    @Test func noCliCommandEverCreatesASendOperation() async throws {
        let h = try Harness()
        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: "S",
                                                                  bodyHTML: "<div>hi</div>", attachments: []),
                                            origin: .cli, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        for env in [Harness.write, ["OPENHUMAN_SAFE_MODE": "normal"]] {
            for meta in CommandCatalog.entries {
                var args = commandArguments(meta.path, draftID: draft.rawValue)
                if meta.confirm { args.append("--yes") }
                if meta.path == "config.set" { continue }
                _ = await h.run(args + ["--json"], environment: env)
            }
        }
        _ = await h.run(["gmail", "send", "--to", "a@example.com"], environment: Self.env)
        _ = await h.run(["gmail", "drafts", "send", draft.rawValue], environment: Self.env)
        let ops = try h.operations()
        #expect(ops.count > 5)
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
                                                                   clock: h.clock, safeMode: .normal), systemEvents: nil)
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
