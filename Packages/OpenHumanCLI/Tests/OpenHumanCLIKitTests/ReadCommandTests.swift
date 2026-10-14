import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanCLIKit

@Suite struct ReadCommandTests {
    @Test func accountsListShowsStatusAndDefault() async throws {
        let h = try Harness()
        let r = await h.run(["accounts", "list", "--json"])
        #expect(r.code == 0)
        #expect(r.json["schema"] as? String == "openhuman.cli/v1")
        #expect(r.json["command"] as? String == "accounts.list")
        let account = try #require(r.list("accounts").first)
        #expect(account["email"] as? String == "me@example.com")
        #expect(account["status"] as? String == "active")
        #expect(account["default"] as? Bool == true)
        #expect(account["scopes"] as? [String] == [GmailScope.modify])
        #expect(account["alias"] == nil)
    }

    @Test func inboxPagesThroughEveryThreadWithTheCursor() async throws {
        let h = try Harness()
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<5 {
            let r = await h.run(["gmail", "inbox", "--max", "1", "--json"] + (cursor.map { ["--cursor", $0] } ?? []))
            #expect(r.code == 0)
            seen += r.list("threads").compactMap { $0["threadId"] as? String }
            cursor = r.meta["nextCursor"] as? String
            if cursor == nil { break }
        }
        #expect(seen == ["t1", "t3", "t2"])
    }

    @Test func listFiltersByViewLabelAndUnread() async throws {
        let h = try Harness()
        func ids(_ args: [String]) async -> [String] {
            await h.run(["gmail", "list"] + args + ["--json"]).list("threads").compactMap { $0["threadId"] as? String }
        }
        #expect(await ids(["--view", "starred"]) == ["t3"])
        #expect(await ids(["--label", "Clients"]) == ["t1"])
        #expect(await ids(["--label", "clients"]) == ["t1"])
        #expect(await ids(["--label", "INBOX", "--unread"]) == ["t1", "t3"])
        #expect(await ids(["--view", "unread"]) == ["t1", "t3"])
        let both = await h.run(["gmail", "list", "--label", "Clients", "--view", "inbox", "--json"])
        #expect(both.code == 2)
        #expect((await h.run(["gmail", "list", "--view", "nope", "--json"])).code == 2)
        #expect((await h.run(["gmail", "list", "--label", "Nope", "--json"])).code == 3)
        #expect((await h.run(["gmail", "list", "--cursor", "!!", "--json"])).errorCode == "bad_cursor")
        #expect((await h.run(["gmail", "list", "--max", "0", "--json"])).code == 2)
    }

    @Test func threadSummaryCarriesTheSpecFields() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "list", "--label", "Clients", "--json"])
        let t = try #require(r.list("threads").first)
        #expect(t["account"] as? String == "me@example.com")
        #expect(t["messageCount"] as? Int == 2)
        #expect(t["unread"] as? Bool == true)
        #expect(t["link"] as? String == "openhuman://thread/me@example.com/t1")
        #expect((t["labels"] as? [String])?.contains("Clients") == true)
        #expect((t["participants"] as? [[String: Any]])?.first?["isMe"] as? Bool == false)
        #expect(t["snoozedUntil"] == nil && t["reminderAt"] == nil)
    }

    @Test func searchFindsThreadsAndReportsCompleteness() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "search", "invoice", "--json"])
        #expect(r.code == 0)
        #expect(r.list("threads").compactMap { $0["threadId"] as? String } == ["t1"])
        #expect(r.data["query"] as? String == "invoice")
        let warnings = r.meta["warnings"] as? [String] ?? []
        #expect(warnings.contains { $0.contains("backfill incomplete") })
        let withMessages = await h.run(["gmail", "search", "from:alice", "--messages", "--json"])
        let matched = try #require(withMessages.list("threads").first?["matchedMessages"] as? [[String: Any]])
        #expect(matched.compactMap { $0["messageId"] as? String } == ["m1"])
        #expect((await h.run(["gmail", "search", "(a b", "--json"])).code == 2)
        let remote = await h.run(["gmail", "search", "invoice", "--remote", "--json"])
        #expect(remote.code == 12 && remote.errorCode == "app_required")
    }

    @Test func getReturnsFormatsHeadersAndBodies() async throws {
        let h = try Harness()
        let full = await h.run(["gmail", "get", "m1", "--json"])
        #expect(full.code == 0)
        let body = try #require(full.data["body"] as? [String: Any])
        #expect(body["text"] as? String == "Invoice attached")
        #expect(body["bodyAvailable"] as? Bool == true)
        #expect(full.data["threadId"] as? String == "t1")
        #expect((full.data["from"] as? [String: Any])?["email"] as? String == "alice@example.com")

        let html = await h.run(["gmail", "get", "m1", "--format", "html", "--json"])
        #expect((html.data["body"] as? [String: Any])?["html"] as? String == "<p>Invoice attached</p>")

        let meta = await h.run(["gmail", "get", "m1", "--format", "metadata", "--json"])
        #expect(meta.data["body"] == nil)
        let names = (meta.data["headers"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(names.contains("From") && names.contains("Subject"))

        let only = await h.run(["gmail", "get", "m1", "--headers", "subject", "--json"])
        #expect((only.data["headers"] as? [[String: Any]])?.count == 1)

        let missing = await h.run(["gmail", "get", "m2", "--json"])
        #expect((missing.data["body"] as? [String: Any])?["bodyAvailable"] as? Bool == false)
        #expect((missing.meta["warnings"] as? [String])?.contains { $0.contains("body not downloaded") } == true)

        #expect((await h.run(["gmail", "get", "nope", "--json"])).code == 3)
        #expect((await h.run(["gmail", "get", "m1", "--format", "raw", "--json"])).code == 12)
        #expect((await h.run(["gmail", "get", "m2", "--fetch", "--json"])).code == 12)
    }

    @Test func threadGetListsMessagesLabelsAndBodies() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "thread", "get", "t1", "--bodies", "--json"])
        #expect(r.code == 0)
        let messages = r.data["messages"] as? [[String: Any]] ?? []
        #expect(messages.compactMap { $0["messageId"] as? String } == ["m1", "m2"])
        #expect((messages[0]["body"] as? [String: Any])?["text"] as? String == "Invoice attached")
        let labels = (r.data["thread"] as? [String: Any])?["labels"] as? [String] ?? []
        #expect(labels.contains("Clients") && labels.contains("INBOX"))
        let plain = await h.run(["gmail", "thread", "get", "t1", "--json"])
        #expect((plain.data["messages"] as? [[String: Any]])?.first?["body"] == nil)
        #expect((await h.run(["gmail", "thread", "get", "zzz", "--json"])).code == 3)
    }

    @Test func labelsHideScheduleLabelsUnlessAll() async throws {
        let h = try Harness()
        func names(_ extra: [String]) async -> [String] {
            await h.run(["gmail", "labels", "list"] + extra + ["--json"]).list("labels").compactMap { $0["name"] as? String }
        }
        let normal = await names([])
        #expect(normal.contains("Clients") && normal.contains("INBOX") && !normal.contains("OpenHuman/Snoozed"))
        #expect(await names(["--all"]).contains("OpenHuman/Snoozed"))
        let counted = await h.run(["gmail", "labels", "list", "--counts", "--json"]).list("labels").first { $0["name"] as? String == "Clients" }
        #expect(counted?["totalThreads"] as? Int == 1 && counted?["unreadThreads"] as? Int == 1)
        let bare = await h.run(["gmail", "labels", "list", "--json"]).list("labels").first { $0["name"] as? String == "Clients" }
        #expect(bare?["totalThreads"] == nil)
        #expect(bare?["type"] as? String == "user")
    }

    @Test func countsAndSplits() async throws {
        let h = try Harness()
        let counts = try #require(await h.run(["gmail", "counts", "--json"]).list("counts").first)
        #expect(counts["inboxUnread"] as? Int == 2)
        #expect(counts["pendingReview"] as? Int == 0)
        let splits = await h.run(["gmail", "splits", "list", "--json"]).list("splits")
        #expect(splits.contains { $0["name"] as? String == "Important" })
        let show = await h.run(["gmail", "splits", "show", "Important", "--json"])
        #expect(show.code == 0)
        #expect((await h.run(["gmail", "splits", "show", "Nope", "--json"])).code == 3)
        #expect((await h.run(["gmail", "inbox", "--split", "important", "--json"])).code == 0)
        #expect((await h.run(["gmail", "inbox", "--other", "--json"])).code == 0)
    }

    @Test func syncStatusAndLog() async throws {
        let h = try Harness()
        try h.store.appendSyncLog(SyncLogEntry(accountID: h.account, startedAt: fixedNow, finishedAt: fixedNow, kind: "incremental",
                                               outcome: "ok", quotaUnits: 5, requests: 1, added: 2))
        let r = await h.run(["sync", "status", "--log", "5", "--json"])
        #expect(r.code == 0)
        let status = try #require(r.list("accounts").first)
        #expect(status["appRunning"] as? Bool == false)
        #expect((status["log"] as? [[String: Any]])?.first?["kind"] as? String == "incremental")
    }

    @Test func staleDataIsAWarningNeverAnError() async throws {
        let h = try Harness()
        let r = await h.run(["gmail", "inbox", "--json"])
        #expect(r.code == 0)
        let account = try #require((r.meta["accounts"] as? [[String: Any]])?.first)
        #expect(account["stale"] as? Bool == true)
        #expect(r.err.contains("OpenHuman Mail is not running"))
        let quiet = await h.run(["gmail", "inbox", "--json", "--quiet"])
        #expect(quiet.err.isEmpty)
        try h.holdLease()
        let live = await h.run(["gmail", "inbox", "--json"])
        #expect((try #require((live.meta["accounts"] as? [[String: Any]])?.first))["stale"] as? Bool == false)
    }

    @Test func severalAccountsNeedAChoice() async throws {
        let h = try Harness()
        let other = try h.store.addAccount(email: "work@example.com", displayName: nil, scopes: [GmailScope.modify])
        try h.store.updateAccount(other, alias: "work", color: nil, position: nil, displayName: nil)
        try h.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try h.store.upsertMessages([.fixture("w1", thread: "tw", minutes: 9, from: "x@example.com", subject: "Work")], account: other, generation: 1)

        let ambiguous = await h.run(["gmail", "inbox", "--json"])
        #expect(ambiguous.code == 2 && ambiguous.errorCode == "account_required")
        let all = await h.run(["gmail", "inbox", "--account", "all", "--json"])
        #expect(all.list("threads").compactMap { $0["threadId"] as? String } == ["tw", "t1", "t3", "t2"])
        let byAlias = await h.run(["gmail", "inbox", "-a", "work", "--json"])
        #expect(byAlias.list("threads").compactMap { $0["threadId"] as? String } == ["tw"])
        #expect((await h.run(["gmail", "inbox", "-a", "nobody@example.com", "--json"])).code == 3)
        #expect((await h.run(["gmail", "list", "--label", "INBOX", "--account", "all", "--json"])).code == 2)
        #expect((await h.run(["gmail", "get", "w1", "--json"])).data["account"] as? String == "work@example.com")
        try h.store.setSetting(.defaultAccount, "work@example.com", scope: .global)
        #expect((await h.run(["gmail", "inbox", "--json"])).list("threads").count == 1)
        try h.store.setSetting(.defaultAccount, nil, scope: .global)
        var seen: [String] = []
        var cursor: String?
        for _ in 0..<6 {
            let r = await h.run(["gmail", "inbox", "--account", "all", "--max", "1", "--json"] + (cursor.map { ["--cursor", $0] } ?? []))
            seen += r.list("threads").compactMap { $0["threadId"] as? String }
            cursor = r.meta["nextCursor"] as? String
            if cursor == nil { break }
        }
        #expect(seen == ["tw", "t1", "t3", "t2"])
    }

    @Test func accountsThatNeedReauthStillReadFromTheCache() async throws {
        let h = try Harness()
        try h.store.setAccountStatus(h.account, .needsReauth)
        let r = await h.run(["gmail", "inbox", "--json"])
        #expect(r.code == 0)
        #expect((r.meta["warnings"] as? [String])?.contains { $0.contains("reauthorized") } == true)
        let write = await h.run(["gmail", "done", "t1", "--json"], environment: Harness.write)
        #expect(write.code == 4)
    }

    @Test func missingStoreAndAccountsAreExit4() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("oh-cli-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty) }
        let h = try Harness(seed: false)
        let none = await h.run(["gmail", "inbox", "--home", empty.path, "--json"])
        #expect(none.code == 4 && none.errorCode == "no_store")
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        try h.store.removeAccountData(h.account) { _ in }
        let noAccount = await h.run(["gmail", "inbox", "--json"])
        #expect(noAccount.code == 4 && noAccount.errorCode == "no_account")
    }

    @Test func readsNeverConstructAnEngineOrWrite() async throws {
        let h = try Harness()
        let before = try h.operations().count
        for args in [["gmail", "inbox"], ["gmail", "search", "invoice"], ["gmail", "get", "m1"], ["gmail", "thread", "get", "t1"],
                     ["gmail", "labels", "list"], ["gmail", "counts"], ["accounts", "list"], ["auth", "status"], ["sync", "status"], ["doctor"]] {
            #expect((await h.run(args + ["--json"])).code == 0)
        }
        #expect(try h.operations().count == before)
    }
}
