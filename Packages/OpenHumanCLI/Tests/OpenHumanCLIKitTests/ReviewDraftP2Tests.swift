import Foundation
import OpenHumanCore
import OpenHumanLinks
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanCLIKit

@Suite struct ReviewDecisionTests {
    func cliDraft(_ h: Harness, subject: String = "Hello", body: String = "First line\nSecond line") throws -> DraftID {
        try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: subject,
                                                      bodyHTML: DraftInput.html(body), bodyText: body, attachments: []),
                                origin: .cli, reviewState: .pending, agentNote: "check it", extraHeaders: [:])
    }

    func approve(_ h: Harness, _ ids: [String], typed: String? = "me@example.com", tty: Bool = true, extra: [String] = []) async -> Run {
        await h.run(["gmail", "review", "approve"] + ids + extra + ["--json"], stdinTTY: tty, readLine: typed)
    }

    @Test func showWithDiffComparesTheReviewersTextWithTheAgents() async throws {
        let h = try Harness()
        let id = try cliDraft(h)
        let plain = await h.run(["gmail", "review", "show", id.rawValue, "--json"])
        #expect(plain.code == 0 && plain.data["draftId"] as? String == id.rawValue && plain.data["diff"] == nil)
        let unchanged = await h.run(["gmail", "review", "show", id.rawValue, "--diff", "--json"])
        let same = try #require(unchanged.data["diff"] as? [String: Any])
        #expect(same["available"] as? Bool == true && same["edited"] as? Bool == false)
        _ = try h.store.updateDraft(id, content: DraftContent(to: [EmailAddress(email: "x@example.com"), EmailAddress(email: "y@example.com")],
                                                              cc: [], bcc: [], subject: "Hello again",
                                                              bodyHTML: DraftInput.html("First line\nA new line"), bodyText: "First line\nA new line",
                                                              attachments: []),
                                    expectedVersion: nil)
        let edited = await h.run(["gmail", "review", "show", id.rawValue, "--diff", "--json"])
        let diff = try #require(edited.data["diff"] as? [String: Any])
        #expect(diff["edited"] as? Bool == true && diff["truncated"] as? Bool == false)
        #expect((diff["subject"] as? [String: Any])?["agent"] as? String == "Hello")
        #expect((diff["subject"] as? [String: Any])?["current"] as? String == "Hello again")
        #expect((diff["to"] as? [String: Any])?["added"] as? [String] == ["y@example.com"])
        let body = diff["body"] as? [[String: Any]] ?? []
        #expect(body.contains { $0["op"] as? String == "removed" && $0["text"] as? String == "Second line" })
        #expect(body.contains { $0["op"] as? String == "added" && $0["text"] as? String == "A new line" })
        let own = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                          content: DraftContent(to: [], cc: [], bcc: [], subject: "mine", bodyHTML: "<div>x</div>", attachments: []),
                                          origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        let mine = await h.run(["gmail", "review", "show", own.rawValue, "--diff", "--json"])
        #expect((mine.data["diff"] as? [String: Any])?["available"] as? Bool == false)
        #expect((await h.run(["gmail", "review", "show", "nope", "--json"])).code == 3)
    }

    @Test func approveIsAPersonsDecisionAndNeverSends() async throws {
        let h = try Harness()
        let id = try cliDraft(h)
        let before = try h.operations().count
        let piped = await approve(h, [id.rawValue], tty: false)
        #expect(piped.code == 5 && piped.errorCode == "person_required")
        let noInput = await approve(h, [id.rawValue], extra: ["--no-input"])
        #expect(noInput.code == 5 && noInput.errorCode == "person_required")
        let wrong = await approve(h, [id.rawValue], typed: "someone@example.com")
        #expect(wrong.code == 5 && wrong.errorCode == "confirmation_failed")
        let nothing = await approve(h, [id.rawValue], typed: nil)
        #expect(nothing.code == 5 && nothing.errorCode == "confirmation_failed")
        #expect(try #require(try h.store.draft(id)).reviewState == .pending)
        #expect(try h.operations().count == before)
        let ok = await approve(h, [id.rawValue])
        #expect(ok.code == 0 || ok.code == 6, "\(ok.code) \(ok.err)")
        #expect(ok.data["review"] as? String == "approved" && ok.data["sent"] as? Bool == false)
        #expect(ok.err.contains("Type the account email to confirm"))
        let draft = try #require(try h.store.draft(id))
        #expect(draft.reviewState == .approved && draft.state == .editing)
        #expect(!(try h.operations()).contains { $0.kind == .sendDraft })
        #expect((await h.run(["gmail", "review", "list", "--json"])).list("drafts").isEmpty)
        let again = await approve(h, [id.rawValue])
        #expect(again.code == 2 && again.errorCode == "not_pending")
    }

    @Test func decisionsAreAllOrNothingAndOnlyForAgentDrafts() async throws {
        let h = try Harness()
        let id = try cliDraft(h)
        let missing = await approve(h, [id.rawValue, "nope"])
        #expect(missing.code == 3)
        #expect(try #require(try h.store.draft(id)).reviewState == .pending)
        let own = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                          content: DraftContent(to: [], cc: [], bcc: [], subject: "mine", bodyHTML: "<div>x</div>", attachments: []),
                                          origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        let mine = await approve(h, [id.rawValue, own.rawValue])
        #expect(mine.code == 5 && mine.errorCode == "not_agent_draft")
        #expect(try #require(try h.store.draft(id)).reviewState == .pending)
        #expect((await approve(h, [])).code == 2)
    }

    @Test func dryRunNeedsNoPersonAndChangesNothing() async throws {
        let h = try Harness()
        let id = try cliDraft(h)
        let before = try h.operations().count
        for verb in ["approve", "reject"] {
            let r = await h.run(["gmail", "review", verb, id.rawValue, "--dry-run", "--json"])
            #expect(r.code == 0 && r.data["dryRun"] as? Bool == true, "\(verb): \(r.code) \(r.err)")
        }
        #expect(try #require(try h.store.draft(id)).reviewState == .pending)
        #expect(try h.operations().count == before)
    }

    @Test func rejectMarksRejectedAndDeletesTheDraft() async throws {
        let h = try Harness()
        let id = try cliDraft(h)
        let r = await h.run(["gmail", "review", "reject", id.rawValue, "--json"], stdinTTY: true, readLine: "ME@example.com")
        #expect(r.code == 0 || r.code == 6, "\(r.code) \(r.err)")
        #expect(r.data["review"] as? String == "rejected" && r.data["sent"] as? Bool == false)
        let draft = try #require(try h.store.draft(id))
        #expect(draft.reviewState == .rejected && draft.state == .discarded)
        #expect((await h.run(["gmail", "review", "list", "--json"])).list("drafts").isEmpty)
        #expect(!(try h.operations()).contains { $0.kind == .sendDraft })
    }

    @Test func openBuildsTheReviewLinkAndOpensItUnlessAskedNotTo() async throws {
        let h = try Harness()
        let empty = await h.run(["gmail", "review", "open", "--json"])
        #expect(empty.code == 0 && empty.data["count"] as? Int == 0 && empty.data["opened"] as? Bool == false && empty.data["link"] == nil)
        let a = try cliDraft(h), b = try cliDraft(h, subject: "Second")
        let opened = OpenedURLs()
        let all = await h.run(["gmail", "review", "open", "--json"], openURL: { opened.append($0) })
        let link = try #require(all.data["link"] as? String)
        #expect(all.code == 0 && all.data["count"] as? Int == 2 && all.data["opened"] as? Bool == true)
        #expect(opened.urls.map(\.absoluteString) == [link])
        guard case .success(.review(let refs)) = MailLinkParser.parse(string: link) else { Issue.record("not a review link"); return }
        #expect(Set(refs.map(\.draftID)) == [a.rawValue, b.rawValue])
        let one = await h.run(["gmail", "review", "open", a.rawValue, "--print-only", "--json"], openURL: { opened.append($0) })
        #expect(one.data["opened"] as? Bool == false && one.data["count"] as? Int == 1)
        #expect(one.data["link"] as? String == "openhuman://review?account=me@example.com&ids=\(a.rawValue)")
        #expect(opened.urls.count == 1)
        #expect((await h.run(["gmail", "review", "open", "nope", "--json"])).code == 3)
    }
}

final class OpenedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Suite struct DraftForwardDeleteTests {
    @Test func forwardMakesAPendingCliForwardDraftAndNeverSends() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "drafts", "forward", "m1", "--to", "Dana <dana@example.com>", "--body", "FYI", "--note", "n", "--json"])
        #expect(r.code == 6, "\(r.code) \(r.err)")
        #expect(r.data["mode"] as? String == "forward" && r.data["origin"] as? String == "cli" && r.data["review"] as? String == "pending")
        #expect(r.data["sent"] as? Bool == false && r.data["reviewLink"] as? String != nil)
        let draft = try #require(try h.store.drafts(account: h.account, states: [], limit: 50).first)
        #expect(draft.composeMode == .forward && draft.content.to.map(\.email) == ["dana@example.com"])
        #expect(draft.content.subject == "Fwd: Invoice for October")
        #expect(draft.content.bodyHTML.hasPrefix("<div dir=\"ltr\">FYI</div>") && draft.content.bodyHTML.contains("Forwarded message"))
        #expect(try h.operations().map(\.kind) == [.upsertDraft])
        let before = try h.store.drafts(account: h.account, states: [], limit: 50).count
        #expect((await h.run(["gmail", "drafts", "forward", "m1", "--json"])).errorCode == "recipient_required")
        #expect((await h.run(["gmail", "drafts", "forward", "nope", "--to", "a@example.com", "--json"])).code == 3)
        #expect((await h.run(["gmail", "drafts", "forward", "m1", "--to", "bad", "--json"])).errorCode == "bad_address")
        let dry = await h.run(["gmail", "drafts", "forward", "m1", "--to", "a@example.com", "--dry-run", "--json"])
        #expect(dry.code == 0 && dry.data["dryRun"] as? Bool == true && dry.data["forwardOf"] as? String == "m1")
        #expect(try h.store.drafts(account: h.account, states: [], limit: 50).count == before)
    }

    @Test func deleteRemovesAnUnapprovedAgentDraftOnly() async throws {
        let h = try Harness()
        _ = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x", "--json"])
        let draft = try #require(try h.store.drafts(account: h.account, states: [], limit: 50).first)
        let unconfirmed = await h.run(["gmail", "drafts", "delete", draft.id.rawValue, "--json"])
        #expect(unconfirmed.code == 2 && unconfirmed.errorCode == "confirmation_required")
        #expect(try #require(try h.store.draft(draft.id)).state == .editing)
        let r = await h.run(["gmail", "drafts", "delete", draft.id.rawValue, "--yes", "--json"])
        #expect(r.code == 0 && r.data["deleted"] as? Bool == true && r.data["status"] as? String == "succeeded", "\(r.code) \(r.err)")
        #expect(try #require(try h.store.draft(draft.id)).state == .discarded)
        #expect(!(try h.operations()).contains { $0.kind == .deleteDraft || $0.kind == .sendDraft })
        let own = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                          content: DraftContent(to: [], cc: [], bcc: [], subject: "mine", bodyHTML: "<div>x</div>", attachments: []),
                                          origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
        let mine = await h.run(["gmail", "drafts", "delete", own.rawValue, "--yes", "--json"])
        #expect(mine.code == 5 && mine.errorCode == "not_agent_draft")
        let approved = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                               content: DraftContent(to: [], cc: [], bcc: [], subject: "ok", bodyHTML: "<div>x</div>", attachments: []),
                                               origin: .agent, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        try h.store.setReviewState(approved, .approved)
        let kept = await h.run(["gmail", "drafts", "delete", approved.rawValue, "--yes", "--json"])
        #expect(kept.code == 5 && kept.errorCode == "draft_approved")
        #expect(try #require(try h.store.draft(own)).state == .editing)
        #expect(try #require(try h.store.draft(approved)).state == .editing)
    }

    @Test func showIsAnAliasOfGet() async throws {
        let h = try Harness()
        _ = await h.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x", "--json"])
        let draft = try #require(try h.store.drafts(account: h.account, states: [], limit: 50).first)
        let shown = await h.run(["gmail", "drafts", "show", draft.id.rawValue, "--json"])
        #expect(shown.code == 0 && shown.json["command"] as? String == "gmail.drafts.get" && shown.data["draftId"] as? String == draft.id.rawValue)
    }
}
