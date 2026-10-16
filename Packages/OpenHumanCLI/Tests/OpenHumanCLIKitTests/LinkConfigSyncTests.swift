import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanLinks
import OpenHumanStore
import Testing
@testable import OpenHumanCLIKit

@Suite struct LinkCommandTests {
    @Test func linksAreWhatTheBuilderProducesAndTheParserAccepts() async throws {
        let h = try Harness()
        let account = AccountRef("me@example.com")
        let thread = await h.run(["link", "thread", "t1", "--json"])
        #expect(thread.data["link"] as? String == MailLinkBuilder.url(for: .thread(account: account, threadID: "t1")).absoluteString)
        #expect(thread.data["link"] as? String == "openhuman://thread/me@example.com/t1")
        let search = await h.run(["link", "search", "from:alice invoice & more", "--json"])
        let searchLink = try #require(search.data["link"] as? String)
        #expect(MailLinkParser.parse(string: searchLink) == .success(.search(query: "from:alice invoice & more", account: account)))
        let compose = await h.run(["link", "compose", "--to", "a@example.com", "--cc", "b@example.com", "--subject", "Hi there", "--body", "Body", "--json"])
        let composeLink = try #require(compose.data["link"] as? String)
        guard case .success(.compose(let prefill)) = MailLinkParser.parse(string: composeLink) else { Issue.record("not a compose link"); return }
        #expect(prefill.to == ["a@example.com"] && prefill.cc == ["b@example.com"] && prefill.subject == "Hi there" && prefill.body == "Body")
        #expect(!composeLink.contains("bcc"))
        #expect((await h.run(["link", "compose", "--to", "bad", "--json"])).code == 2)

        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                            content: DraftContent(to: [EmailAddress(email: "x@example.com")], cc: [], bcc: [], subject: "S",
                                                                  bodyHTML: "<div>hi</div>", attachments: []),
                                            origin: .cli, reviewState: .pending, agentNote: nil, extraHeaders: [:])
        let draftLink = await h.run(["link", "draft", draft.rawValue, "--json"])
        #expect(draftLink.data["link"] as? String == "openhuman://draft/me@example.com/\(draft.rawValue)")
        let review = await h.run(["link", "review", draft.rawValue, "--json"])
        let reviewLink = try #require(review.data["link"] as? String)
        #expect(reviewLink == "openhuman://review?account=me@example.com&ids=\(draft.rawValue)")
        #expect(MailLinkParser.parse(string: reviewLink) == .success(.review([DraftRef(account: account, draftID: draft.rawValue)])))
        #expect((await h.run(["link", "review", "nope", "--json"])).code == 3)
        #expect((await h.run(["link", "review", "--json"])).code == 2)
    }

    @Test func hostileInputIsRefusedNotPutInALink() async throws {
        let h = try Harness()
        for id in ["../etc/passwd", "javascript:alert(1)", "a b", String(repeating: "a", count: 5000), "t1/../../x"] {
            let r = await h.run(["link", "thread", id, "--json"])
            #expect(r.code == 2 && r.errorCode == "bad_link_input", "\(id.prefix(20)): \(r.code)")
        }
        let huge = await h.run(["link", "search", String(repeating: "q", count: 50_000), "--json"])
        #expect(huge.code == 2)
        #expect((await h.run(["link", "thread", "t1", "-a", "nobody@example.com", "--json"])).code == 3)
    }

    @Test func openRunsTheSystemOpenerOnlyOnRequest() async throws {
        let h = try Harness()
        let opened = Locked<[URL]>([])
        _ = await h.run(["link", "thread", "t1", "--json"], openURL: { url in opened.withLock { $0.append(url) } })
        #expect(opened.withLock { $0 }.isEmpty)
        _ = await h.run(["link", "thread", "t1", "--open", "--json"], openURL: { url in opened.withLock { $0.append(url) } })
        #expect(opened.withLock { $0 }.map(\.absoluteString) == ["openhuman://thread/me@example.com/t1"])
        _ = await h.run(["link", "thread", "t1", "--open", "--dry-run", "--json"], openURL: { url in opened.withLock { $0.append(url) } })
        #expect(opened.withLock { $0 }.count == 1)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

@Suite struct ConfigAndSyncTests {
    @Test func settingsRoundTripAndValidate() async throws {
        let h = try Harness()
        let list = await h.run(["config", "list", "--json"])
        let keys = list.list("settings").compactMap { $0["key"] as? String }
        #expect(keys.contains("default_account") && keys.contains("cli.readonly_default") && keys.contains("cli.allowed_commands"))
        #expect((await h.run(["config", "get", "undo_send_seconds", "--json"])).data["value"] as? Int == 10)
        let set = await h.run(["config", "set", "poll_interval_seconds", "120", "--json"])
        #expect(set.code == 0 && set.data["value"] as? Int == 120)
        #expect(try h.store.setting(.pollIntervalSeconds, scope: .global) == 120)
        #expect((await h.run(["config", "set", "poll_interval_seconds", "999999", "--json"])).errorCode == "bad_value")
        #expect((await h.run(["config", "set", "snooze_mark_unread", "maybe", "--json"])).errorCode == "bad_value")
        #expect((await h.run(["config", "get", "nope", "--json"])).errorCode == "unknown_key")
        #expect((await h.run(["config", "get", "sync.download_bodies", "--json"])).data["value"] as? Bool == true)
        #expect((await h.run(["config", "set", "sync.body_max_messages", "5000", "--json"])).code == 0)
        #expect(try h.store.setting(.bodyMaxMessages, scope: .global) == 5_000)
        #expect((await h.run(["config", "set", "sync.body_max_messages", "none", "--json"])).code == 0)
        #expect(try h.store.setting(.bodyMaxMessages, scope: .global) == nil)
        let alias = await h.run(["accounts", "alias", "me@example.com", "mine", "--json"])
        #expect(alias.code == 0)
        let listed = await h.run(["accounts", "list", "--json"])
        #expect(listed.list("accounts").first?["alias"] as? String == "mine")
        #expect((await h.run(["accounts", "alias", "me@example.com", "bad alias", "--json"])).errorCode == "bad_alias")
        #expect((await h.run(["accounts", "default", "mine", "--json"])).code == 0)
        #expect(try h.store.setting(.defaultAccount, scope: .global) == "me@example.com")
        let dry = await h.run(["config", "set", "poll_interval_seconds", "300", "--dry-run", "--json"])
        #expect(dry.code == 0)
        #expect(try h.store.setting(.pollIntervalSeconds, scope: .global) == 120)
    }

    @Test func mailGuardRailsAreSafetyKeys() async throws {
        let h = try Harness()
        let piped = await h.run(["config", "set", "undo_send_seconds", "0", "--json"])
        #expect(piped.code == 5 && piped.errorCode == "safety_key_gated")
        let noInput = await h.run(["config", "set", "undo_send_seconds", "0", "--no-input", "--json"], stdinTTY: true, readLine: "me@example.com")
        #expect(noInput.code == 5 && noInput.errorCode == "safety_key_gated")
        for key in ["scheduler.send_later.enabled", "scheduler.snooze.enabled", "scheduler.reminders.enabled"] {
            let gated = await h.run(["config", "set", key, "false", "--json"])
            #expect(gated.code == 5 && gated.errorCode == "safety_key_gated", "\(key)")
        }
        #expect(try h.store.setting(.schedulerSendLaterEnabled, scope: .global) == true)
        let wrong = await h.run(["config", "set", "undo_send_seconds", "0", "--json"], stdinTTY: true, readLine: "someone@example.com")
        #expect(wrong.code == 5 && wrong.errorCode == "confirmation_failed")
        #expect(try h.store.setting(.undoSendSeconds, scope: .global) == 10)
        let confirmed = await h.run(["config", "set", "undo_send_seconds", "5", "--json"], stdinTTY: true, readLine: "me@example.com")
        #expect(confirmed.code == 0 && confirmed.data["safety"] as? Bool == true)
        #expect(try h.store.setting(.undoSendSeconds, scope: .global) == 5)
        let listed = (await h.run(["config", "list", "--json"])).list("settings")
        #expect(listed.first { $0["key"] as? String == "undo_send_seconds" }?["safety"] as? Bool == true)
    }

    @Test func safetyKeysNeedATerminalAndTheAccountEmail() async throws {
        let h = try Harness()
        let args = ["config", "set", "cli.readonly_default", "true", "--json"]
        let piped = await h.run(args, stdinTTY: false, readLine: "me@example.com")
        #expect(piped.code == 5 && piped.errorCode == "safety_key_gated")
        let noInput = await h.run(args + ["--no-input"], stdinTTY: true, readLine: "me@example.com")
        #expect(noInput.code == 5 && noInput.errorCode == "safety_key_gated")
        let readonly = await h.run(args + ["--readonly"], stdinTTY: true, readLine: "me@example.com")
        #expect(readonly.code == 5)
        #expect(try h.store.setting(.cliReadonlyDefault, scope: .global) == false)
        let wrong = await h.run(args, stdinTTY: true, readLine: "someone@else.com")
        #expect(wrong.code == 5 && wrong.errorCode == "confirmation_failed")
        let noAnswer = await h.run(args, stdinTTY: true, readLine: nil)
        #expect(noAnswer.code == 5)
        #expect(try h.store.setting(.cliReadonlyDefault, scope: .global) == false)
        let allow = await h.run(["config", "set", "cli.allowed_commands", "gmail.search,gmail.nope", "--json"], stdinTTY: true, readLine: "me@example.com")
        #expect(allow.errorCode == "unknown_command")
        #expect(try h.store.setting(.cliAllowedCommands, scope: .global) == nil)
        let right = await h.run(args, stdinTTY: true, readLine: " ME@example.com ")
        #expect(right.code == 0 && right.data["value"] as? Bool == true)
        #expect(right.err.contains("Type the account email"))
        #expect(try h.store.setting(.cliReadonlyDefault, scope: .global) == true)
        #expect((await h.run(["config", "set", "undo_send_seconds", "5", "--json"])).code == 5)
        #expect((await h.run(["accounts", "alias", "me@example.com", "x", "--json"])).code == 5)
        let lift = await h.run(["config", "set", "cli.readonly_default", "false", "--json"], stdinTTY: true, readLine: "me@example.com")
        #expect(lift.code == 0)
        #expect(try h.store.setting(.cliReadonlyDefault, scope: .global) == false)
        #expect((await h.run(["config", "set", "cli.readonly_default", "true", "--json", "--readonly"], stdinTTY: true, readLine: "me@example.com")).code == 5)
    }

    @Test func syncRunOnlyAsksARunningApp() async throws {
        let h = try Harness()
        let noOwner = await h.run(["sync", "run", "--json"])
        #expect(noOwner.code == 12 && noOwner.errorCode == "app_required")
        #expect(noOwner.error["message"] as? String == "Sync runs in OpenHuman Mail. Open the app; cached data is never synced.")
        #expect(try h.store.setting(.syncRequestAt, scope: .global) == nil)
        try h.holdLease()
        try h.store.updateSyncState(account: h.account) { $0.lastSuccessAt = fixedNow.addingTimeInterval(-90) }
        let ok = await h.run(["sync", "run", "--json"])
        #expect(ok.code == 0 && ok.data["requested"] as? Bool == true)
        #expect(ok.data["ownerPid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        #expect(ok.data["dataAgeSeconds"] as? Int == 90)
        #expect(ok.err.contains("sync is owned by the app (pid \(ProcessInfo.processInfo.processIdentifier)); data is 90 s fresh"))
        let stamped = try #require(try h.store.setting(.syncRequestAt, scope: .global))
        #expect(stamped == Int(fixedNow.timeIntervalSince1970 * 1000))
        let dry = await h.run(["sync", "run", "--dry-run", "--json"])
        #expect(dry.code == 0 && dry.data["requested"] as? Bool == false)
        let full = await h.run(["sync", "run", "--full", "--json"])
        #expect((full.meta["warnings"] as? [String])?.contains { $0.contains("--full") } == true)
        #expect((await h.run(["sync", "run", "--readonly", "--json"])).code == 5)
    }

    @Test func doctorReportsTheStoreWithoutContent() async throws {
        let h = try Harness()
        let r = await h.run(["doctor", "--json"])
        #expect(r.code == 0 && r.data["ok"] as? Bool == true)
        let checks = r.list("checks")
        let names = checks.compactMap { $0["name"] as? String }
        #expect(["cli", "store.open", "sqlite", "accounts", "app", "queue", "policy"].allSatisfy(names.contains))
        #expect(!r.out.contains("Invoice") && !r.out.contains("alice@example.com"))
        let temp = TemporaryDirectory("oh-cli-doctor")
        defer { temp.cleanup() }
        let empty = temp.url
        let none = await h.run(["doctor", "--home", empty.path, "--json"])
        #expect(none.code == 4 && none.data["ok"] as? Bool == false)
    }
}
