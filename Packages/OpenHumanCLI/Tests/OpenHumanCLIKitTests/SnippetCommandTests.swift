import Foundation
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanCLIKit

@Suite struct SnippetCommandTests {
    static let appFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OpenHumanCore/Tests/OpenHumanCoreTests/Fixtures/snippets-v2.json")

    func add(_ h: Harness, _ args: [String], environment: [String: String] = [:]) async -> Run {
        await h.run(["gmail", "snippets", "add"] + args + ["--json"], environment: environment)
    }

    func appSnippet(_ h: Harness, name: String = "Terms") throws -> SnippetItem {
        let file = try h.store.storeSnippetAttachment(data: Data("Synthetic terms.\n".utf8), filename: "terms.txt", mimeType: "text/plain")
        let item = SnippetItem(id: UUID().uuidString, name: name, shortcut: "terms", subject: "Our terms", bodyHTML: "<p>Old</p>",
                               variables: [], useCount: 3, to: [EmailAddress(name: "Dana Ruiz", email: "dana@example.com")],
                               cc: [EmailAddress(email: "lee@example.com")], bcc: [EmailAddress(email: "records@example.com")],
                               attachments: [file])
        try h.store.upsertSnippet(item)
        return item
    }

    @Test func addReplaceChangesTheTextAndKeepsRecipientsAndFiles() async throws {
        let h = try Harness()
        let before = try appSnippet(h)
        let replaced = await add(h, ["Terms", "--body", "New text", "--replace"])
        #expect(replaced.code == 0 && replaced.data["status"] as? String == "replaced", "\(replaced.code) \(replaced.err)")
        let after = try #require(try h.store.snippets(account: nil).first { $0.id == before.id })
        #expect(after.bodyHTML == DraftInput.html("New text"))
        #expect(after.to == before.to && after.cc == before.cc && after.bcc == before.bcc)
        #expect(after.attachments == before.attachments && after.useCount == 3)
        let file = try #require(StoreLocation(directory: h.directory).snippetFileURL(before.attachments[0]))
        #expect(try Data(contentsOf: file) == Data("Synthetic terms.\n".utf8))
    }

    @Test func importingAVersion1FileKeepsTheReplacedSnippetsRecipientsAndFiles() async throws {
        let h = try Harness()
        let before = try appSnippet(h)
        let v1 = SnippetsFile(snippets: [.init(name: "terms", shortcut: nil, subject: nil, bodyHTML: "<p>New</p>", variables: [])])
        #expect(v1.version == 1)
        let url = h.directory.appendingPathComponent("v1.json")
        try v1.encoded().write(to: url)
        let done = await h.run(["gmail", "snippets", "import", url.path, "--yes", "--json"])
        #expect(done.code == 0 && done.data["toReplace"] as? Int == 1, "\(done.code) \(done.err)")
        let after = try #require(try h.store.snippets(account: nil).first { $0.id == before.id })
        #expect(after.bodyHTML == "<p>New</p>")
        #expect(after.to == before.to && after.cc == before.cc && after.bcc == before.bcc && after.attachments == before.attachments)
    }

    @Test func theAppsVersion2FileImportsWithBccAndFilesAndExportsUnchanged() async throws {
        let h = try Harness()
        let appFile = try Data(contentsOf: Self.appFile)
        let preview = await h.run(["gmail", "snippets", "import", Self.appFile.path, "--dry-run", "--json"])
        #expect(preview.code == 0 && preview.data["toAdd"] as? Int == 2, "\(preview.code) \(preview.err)")
        #expect(preview.data["withRecipients"] as? Int == 1 && preview.data["files"] as? Int == 1 && preview.data["filesDropped"] as? Int == 0)
        let done = await h.run(["gmail", "snippets", "import", Self.appFile.path, "--yes", "--json"])
        #expect(done.code == 0 && done.data["saved"] as? Int == 2, "\(done.code) \(done.err)")
        let onboarding = try #require(try h.store.snippets(account: nil).first { $0.name == "Onboarding" })
        #expect(onboarding.to == [EmailAddress(name: "Dana Ruiz", email: "dana@example.com")])
        #expect(onboarding.cc == [EmailAddress(email: "team@example.com")] && onboarding.bcc == [EmailAddress(email: "records@example.com")])
        #expect(onboarding.attachments.map(\.filename) == ["guide.txt"])
        let stored = try #require(StoreLocation(directory: h.directory).snippetFileURL(onboarding.attachments[0]))
        #expect(try Data(contentsOf: stored) == Data("Synthetic onboarding guide.\n".utf8))

        let out = h.directory.appendingPathComponent("again.json")
        let exported = await h.run(["gmail", "snippets", "export", "--out", out.path, "--json"])
        #expect(exported.code == 0 && exported.data["version"] as? Int == 2)
        #expect(try Data(contentsOf: out) == appFile, "the app reads back exactly the file it wrote")
        let inline = await h.run(["gmail", "snippets", "export", "--json"])
        let entry = try #require(((inline.data["file"] as? [String: Any])?["snippets"] as? [[String: Any]])?.first)
        #expect((entry["bcc"] as? [[String: Any]])?.first?["email"] as? String == "records@example.com")
        #expect((entry["files"] as? [[String: Any]])?.first?["filename"] as? String == "guide.txt")
    }

    @Test func addHonoursReadonlyAndDryRun() async throws {
        let h = try Harness()
        let readonly = await add(h, ["Thanks", "--body", "Thank you", "--readonly"])
        #expect(readonly.code == 5 && readonly.errorCode == "readonly")
        let dry = await add(h, ["Thanks", "--body", "Thank you", "--dry-run"])
        #expect(dry.code == 0 && dry.data["dryRun"] as? Bool == true)
        #expect(try h.store.snippets(account: nil).isEmpty)
        let added = await add(h, ["Thanks", "--body", "Thank you"])
        #expect(added.code == 0 && added.data["status"] as? String == "added", "\(added.code) \(added.err)")
        #expect(try h.store.snippets(account: nil).count == 1)
        #expect(try h.operations().isEmpty)
    }

    @Test func addListShowRenderAndDelete() async throws {
        let h = try Harness()
        let r = await add(h, ["Thanks", "--body", "Hi {{first_name}}, thanks for {{topic}}. See you {{date+1}}. \\{{literal}}",
                              "--subject", "Thanks, {{first_name}}", "--shortcut", ";;THX", "--var", "topic=the call"])
        #expect(r.code == 0 && r.data["status"] as? String == "added", "\(r.code) \(r.err)")
        #expect(r.data["shortcut"] as? String == "thx" && r.data["account"] as? String == "all")
        let id = try #require(r.data["snippetId"] as? String)
        #expect((await add(h, ["thanks", "--body", "x"])).errorCode == "snippet_exists")
        #expect((await add(h, ["Other", "--body", "x", "--shortcut", "thx"])).errorCode == "shortcut_taken")
        #expect((await add(h, ["Other", "--body", "x", "--var", "Bad-Name"])).errorCode == "bad_var")
        #expect((await add(h, ["Other"])).errorCode == "body_required")
        #expect((await add(h, ["Mine", "--body", "Just mine", "--account", "me@example.com"])).data["account"] as? String == "me@example.com")

        let list = await h.run(["gmail", "snippets", "list", "--json"])
        #expect(list.code == 0 && list.list("snippets").compactMap { $0["name"] as? String } == ["Mine", "Thanks"])
        for key in [";;thx", "THANKS", id] {
            let shown = await h.run(["gmail", "snippets", "show", key, "--json"])
            #expect(shown.code == 0 && shown.data["snippetId"] as? String == id && shown.data["bodyHtml"] as? String != nil, "\(key)")
        }
        #expect((await h.run(["gmail", "snippets", "show", "nope", "--json"])).code == 3)

        let filled = await h.run(["gmail", "snippets", "render", "Thanks", "--to", "Dana Ruiz <dana@example.com>", "--json"])
        #expect(filled.code == 0)
        let text = try #require(filled.data["bodyText"] as? String)
        #expect(text.hasPrefix("Hi Dana, thanks for the call. See you ") && text.hasSuffix("{{literal}}"))
        #expect(!text.contains("date+1"))
        #expect(filled.data["subject"] as? String == "Thanks, Dana")
        #expect((filled.data["unresolved"] as? [String])?.isEmpty == true)
        let bare = await h.run(["gmail", "snippets", "render", "Thanks", "--json"])
        #expect(bare.data["unresolved"] as? [String] == ["first_name"])
        #expect((bare.data["bodyText"] as? String)?.hasPrefix("Hi first_name, thanks for the call.") == true)
        let typed = await h.run(["gmail", "snippets", "render", "thx", "--var", "first_name=<Sam>", "--json"])
        #expect((typed.data["bodyHtml"] as? String)?.contains("Hi &lt;Sam&gt;,") == true)
        #expect((await h.run(["gmail", "snippets", "render", "Thanks", "--var", "nope", "--json"])).errorCode == "bad_var")

        let replaced = await add(h, ["Thanks", "--body", "New text", "--replace"])
        #expect(replaced.code == 0 && replaced.data["status"] as? String == "replaced" && replaced.data["snippetId"] as? String == id)
        let unconfirmed = await h.run(["gmail", "snippets", "delete", "Thanks", "--json"])
        #expect(unconfirmed.code == 2 && unconfirmed.errorCode == "confirmation_required")
        let deleted = await h.run(["gmail", "snippets", "delete", "Thanks", "--yes", "--json"])
        #expect(deleted.code == 0 && deleted.data["deleted"] as? Bool == true)
        #expect(try h.store.snippets(account: nil).map(\.name) == ["Mine"])
        #expect(try h.operations().isEmpty)
    }

    @Test func exportWritesTheAppsFileWithoutAccountAddresses() async throws {
        let h = try Harness()
        _ = await add(h, ["Zeta", "--body", "Last", "--account", "me@example.com"])
        _ = await add(h, ["alpha", "--body", "First {{x}}", "--shortcut", "a1", "--var", "x=1", "--subject", "S"])
        let inline = await h.run(["gmail", "snippets", "export", "--json"])
        #expect(inline.code == 0 && inline.data["count"] as? Int == 2)
        let file = try #require(inline.data["file"] as? [String: Any])
        #expect(file["format"] as? String == "openhuman-snippets" && file["version"] as? Int == 1)
        #expect((file["snippets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["alpha", "Zeta"])

        let url = h.directory.appendingPathComponent("shared-snippets.json")
        let written = await h.run(["gmail", "snippets", "export", "--out", url.path, "--json"])
        #expect(written.code == 0 && written.data["path"] as? String == url.path)
        let bytes = try Data(contentsOf: url)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("me@example.com") && !text.contains("account"))
        let decoded = try JSONDecoder().decode(SnippetFile.self, from: bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(try encoder.encode(decoded) == bytes)
        #expect(decoded.snippets[0] == SnippetFile.Snippet(name: "alpha", shortcut: "a1", subject: "S", bodyHTML: DraftInput.html("First {{x}}"),
                                                           variables: [SnippetFile.Variable(name: "x", defaultValue: "1")]))
        #expect(decoded.snippets[1].shortcut == nil && decoded.snippets[1].subject == nil && !text.contains("null"))
        let again = await h.run(["gmail", "snippets", "export", "--out", url.path, "--json"])
        #expect(again.code == 2 && again.errorCode == "file_exists")
        #expect((await h.run(["gmail", "snippets", "export", "--out", url.path, "--force", "--json"])).code == 0)
    }

    @Test func importPreviewsThenAddsOrReplacesByNameAndNeverDeletes() async throws {
        let h = try Harness()
        let thanks = await add(h, ["Thanks", "--body", "Old", "--shortcut", "thx"])
        let thanksID = try #require(thanks.data["snippetId"] as? String)
        _ = await add(h, ["Keep me", "--body", "Untouched"])
        let incoming = SnippetFile(snippets: [
            .init(name: "THANKS", shortcut: nil, subject: "New subject", bodyHTML: "<div>New</div>", variables: []),
            .init(name: "Intro", shortcut: ";;thx", subject: nil, bodyHTML: "<div>Hello {{name}}</div>",
                  variables: [.init(name: "name", defaultValue: "there")]),
            .init(name: "  ", shortcut: nil, subject: nil, bodyHTML: "<div>no name</div>", variables: []),
            .init(name: "Empty", shortcut: nil, subject: nil, bodyHTML: "  ", variables: []),
            .init(name: "intro", shortcut: nil, subject: nil, bodyHTML: "<div>duplicate name</div>", variables: []),
        ])
        let url = h.directory.appendingPathComponent("incoming.json")
        try incoming.encoded().write(to: url)

        let preview = await h.run(["gmail", "snippets", "import", url.path, "--dry-run", "--json"])
        #expect(preview.code == 0 && preview.data["status"] as? String == "dry_run", "\(preview.code) \(preview.err)")
        #expect(preview.data["toAdd"] as? Int == 1 && preview.data["toReplace"] as? Int == 1 && preview.data["shortcutsDropped"] as? Int == 1)
        #expect(try h.store.snippets(account: nil).count == 2)
        let unconfirmed = await h.run(["gmail", "snippets", "import", url.path, "--json"])
        #expect(unconfirmed.code == 2 && unconfirmed.errorCode == "confirmation_required")
        let done = await h.run(["gmail", "snippets", "import", url.path, "--yes", "--json"])
        #expect(done.code == 0 && done.data["status"] as? String == "imported" && done.data["saved"] as? Int == 2, "\(done.code) \(done.err)")
        let stored = try h.store.snippets(account: nil)
        #expect(stored.map(\.name).sorted() == ["Intro", "Keep me", "THANKS"])
        let replaced = try #require(stored.first { $0.id == thanksID })
        #expect(replaced.bodyHTML == "<div>New</div>" && replaced.subject == "New subject" && replaced.shortcut == nil)
        let intro = try #require(stored.first { $0.name == "Intro" })
        #expect(intro.shortcut == nil && intro.variables == [SnippetVariable(name: "name", defaultValue: "there")])
        #expect(stored.contains { $0.name == "Keep me" && $0.bodyHTML == DraftInput.html("Untouched") })
        #expect(try h.operations().isEmpty)
    }

    @Test func importRefusesOtherFilesAndNewerVersions() async throws {
        let h = try Harness()
        let settings = h.directory.appendingPathComponent("settings.json")
        try Data(#"{"format":"openhuman-settings","version":1,"snippets":[]}"#.utf8).write(to: settings)
        let wrong = await h.run(["gmail", "snippets", "import", settings.path, "--yes", "--json"])
        #expect(wrong.code == 2 && wrong.errorCode == "not_a_snippets_file")
        let newer = h.directory.appendingPathComponent("newer.json")
        try Data(#"{"format":"openhuman-snippets","version":3,"snippets":[]}"#.utf8).write(to: newer)
        let tooNew = await h.run(["gmail", "snippets", "import", newer.path, "--yes", "--json"])
        #expect(tooNew.code == 9 && tooNew.errorCode == "snippets_file_too_new")
        let missing = await h.run(["gmail", "snippets", "import", "/nonexistent/x.json", "--yes", "--json"])
        #expect(missing.code == 2 && missing.errorCode == "bad_file")
        #expect(try h.store.snippets(account: nil).isEmpty)
    }
}
