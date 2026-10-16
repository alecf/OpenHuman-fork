import Foundation
import Testing
@testable import OpenHumanCLIKit

@Suite struct SchemaTests {
    static let spec4: [String] = [
        "accounts.list", "accounts.add", "accounts.remove", "accounts.alias", "accounts.default",
        "auth.status", "auth.login", "auth.logout", "sync.run", "sync.status", "sync.watch",
        "gmail.search", "gmail.list", "gmail.inbox", "gmail.get", "gmail.thread.get", "gmail.thread.modify", "gmail.batch.modify",
        "gmail.done", "gmail.move-to-inbox", "gmail.read", "gmail.unread", "gmail.star", "gmail.unstar",
        "gmail.trash", "gmail.untrash", "gmail.spam", "gmail.not-spam", "gmail.snooze", "gmail.unsnooze", "gmail.remind", "gmail.unremind",
        "gmail.labels.list", "gmail.labels.create", "gmail.counts",
        "gmail.splits.list", "gmail.splits.show", "gmail.splits.create", "gmail.splits.update", "gmail.splits.delete", "gmail.splits.reorder",
        "gmail.drafts.list", "gmail.drafts.get", "gmail.drafts.create", "gmail.drafts.update", "gmail.drafts.reply",
        "gmail.drafts.forward", "gmail.drafts.delete",
        "gmail.review.list", "gmail.review.show", "gmail.review.approve", "gmail.review.reject", "gmail.review.open",
        "gmail.snippets.list", "gmail.snippets.show", "gmail.snippets.render",
        "gmail.snippets.add", "gmail.snippets.delete", "gmail.snippets.export", "gmail.snippets.import", "gmail.undo",
        "gmail.attachments.get", "gmail.history",
        "calendar.events", "link.thread", "link.draft", "link.review", "link.search", "link.compose",
        "schema", "doctor", "config.get", "config.list", "config.set", "mcp",
    ]

    static let catalogCLIPaths: [String] = [
        "gmail.done", "gmail.move-to-inbox", "gmail.trash", "gmail.untrash", "gmail.star", "gmail.unstar", "gmail.read", "gmail.unread",
        "gmail.spam", "gmail.not-spam", "gmail.snooze", "gmail.unsnooze", "gmail.remind", "gmail.unremind", "gmail.thread.modify",
        "gmail.labels.create", "link.compose", "gmail.review.approve", "gmail.review.reject", "gmail.review.open", "link.review", "gmail.search",
    ]

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func schema(_ h: Harness) async throws -> (run: Run, commands: [[String: Any]]) {
        let r = await h.run(["schema", "--json"])
        #expect(r.code == 0)
        return (r, r.data["commands"] as? [[String: Any]] ?? [])
    }

    @Test func everyCommandOfSection4IsInTheSchema() async throws {
        let h = try Harness(seed: false)
        let (_, commands) = try await schema(h)
        let paths = commands.compactMap { $0["path"] as? String }
        for path in Self.spec4 { #expect(paths.contains(path), "\(path) missing from the schema") }
        let reservedPaths = ["gmail.send", "gmail.reply", "gmail.reply-all", "gmail.forward", "gmail.drafts.send", "gmail.filters"]
        for path in reservedPaths { #expect(paths.contains(path)) }
        #expect(Set(paths).count == paths.count)
        #expect(paths.count == Self.spec4.count + reservedPaths.count)
        #expect(paths == paths.sorted())
        let all = Set(paths + commands.flatMap { ($0["aliases"] as? [String]) ?? [] })
        for path in Self.catalogCLIPaths { #expect(all.contains(path), "\(path)") }
        #expect(all.contains("gmail.archive") && all.contains("gmail.unarchive") && all.contains("gmail.drafts.show"))
    }

    @Test func theTreeAndTheCatalogAgree() throws {
        let built = try SchemaBuilder.build().map(\.meta.path).sorted()
        #expect(built == CommandCatalog.entries.map(\.path).sorted())
        for meta in CommandCatalog.entries { #expect(CommandCatalog.meta(for: meta.path)?.path == meta.path) }
    }

    @Test func implementedFlagsMatchTheStages() async throws {
        let h = try Harness(seed: false)
        let (_, commands) = try await schema(h)
        for command in commands {
            let path = command["path"] as? String ?? ""
            let stage = command["stage"] as? String ?? ""
            let implemented = command["implemented"] as? Bool ?? false
            #expect(implemented == (["1", "1b", "1c"].contains(stage) && command["reserved"] == nil && command["network"] as? Bool != true), "\(path)")
            if implemented { #expect(!((command["plainColumns"] as? [String]) ?? []).isEmpty || ["schema", "sync.watch"].contains(path), "\(path) has no plain columns") }
            #expect(command["output"] as? String != nil && command["priority"] as? String != nil)
            #expect(command["writes"] as? Bool == (command["writeScope"] as? String != "none"))
        }
        let done = try #require(commands.first { $0["path"] as? String == "gmail.done" })
        #expect(done["aliases"] as? [String] == ["gmail.archive"] && done["stage"] as? String == "1b" && done["writeScope"] as? String == "mailChange")
        let search = try #require(commands.first { $0["path"] as? String == "gmail.search" })
        #expect((search["arguments"] as? [[String: Any]])?.first?["name"] as? String == "query")
        let optionNames = (search["options"] as? [[String: Any]])?.flatMap { $0["names"] as? [String] ?? [] } ?? []
        #expect(optionNames.contains("--max") && optionNames.contains("--cursor") && optionNames.contains("--remote"))
        #expect(!optionNames.contains("--json"))
        let globals = (await h.run(["schema", "--json"]).data["globalOptions"] as? [[String: Any]])?.flatMap { $0["names"] as? [String] ?? [] } ?? []
        #expect(globals.contains("--json") && globals.contains("--readonly") && globals.contains("--wrap-untrusted"))
        let codes = (await h.run(["schema", "--json"]).data["exitCodes"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }
        #expect(codes == Array(0...13))
    }

    @Test func schemaOfOneCommand() async throws {
        let h = try Harness(seed: false)
        for spelling in [["gmail.search"], ["gmail", "search"], ["gmail.archive"]] {
            let one = await h.run(["schema"] + spelling + ["--json"])
            #expect(one.code == 0)
            #expect((one.data["commands"] as? [[String: Any]])?.count == 1)
        }
        #expect((await h.run(["schema", "gmail.nope", "--json"])).code == 3)
        #expect((await h.run(["schema", "--plain"])).out.contains("gmail.done\t1b\t1\tmailChange"))
        #expect((await h.run(["schema", "--plain"])).out.contains("gmail.drafts.create\t1b\t1\tagentDraft"))
    }

    @Test func theCommittedSchemaIsFresh() async throws {
        let h = try Harness(seed: false)
        let generated = await h.run(["schema", "--json"])
        let file = Self.repoRoot.appendingPathComponent("docs/cli/schema.json")
        let committed = try String(contentsOf: file, encoding: .utf8)
        #expect(committed == generated.out, "docs/cli/schema.json is stale: run `openhuman schema --json > docs/cli/schema.json`")
    }

    @Test func theSchemaIsIdenticalWhateverTheEnvironment() async throws {
        let h = try Harness(seed: false)
        let a = await h.run(["schema", "--json"])
        let b = await h.run(["schema", "--json", "--wrap-untrusted"], environment: ["OPENHUMAN_READONLY": "1"], timeZone: "Asia/Tokyo")
        #expect(a.data["commands"] as? NSArray == b.data["commands"] as? NSArray)
    }
}
