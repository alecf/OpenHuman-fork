import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SnippetTransferTests {
    private func add(_ f: SettingsFixture, _ name: String, shortcut: String? = nil, account: AccountID? = nil,
                     body: String = "Thanks, {{first_name}}.") async throws {
        _ = try await f.store.upsertSnippet(SnippetInfo(account: account, name: name, shortcut: shortcut, subject: nil,
                                                        bodyHTML: SnippetBody.html(fromPlain: body),
                                                        variables: [SnippetVariableInfo(name: "x", defaultValue: "y")]))
    }

    @Test func exportThenImportOnAnotherMacAddsByNameWithoutAddresses() async throws {
        let a = SettingsFixture()
        try await add(a, "Sign-off", shortcut: "so")
        try await add(a, "Work intro", account: a.work, body: "Hi, I lead the design team.")
        let file = try await SnippetTransferModel(environment: a.env).export()
        let bundle = try JSONDecoder().decode(SnippetBundle.self, from: file)
        #expect(bundle.format == "openhuman-snippets" && bundle.version == 1)
        let json = try #require(String(data: file, encoding: .utf8))
        for account in try await a.accounts() { #expect(!json.contains(account.email), "no account address in a shared file") }
        #expect(bundle.snippets.contains { $0.name == "Sign-off" && $0.shortcut == "so" })

        let b = SettingsFixture()
        let before = try await b.snippets()
        let model = SnippetTransferModel(environment: b.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.toAdd + preview.toReplace == bundle.snippets.count && preview.toAdd >= 1)
        #expect(preview.storedItemsNote == nil)
        #expect(try await b.snippets() == before, "the preview writes nothing")
        let line = await model.applyImport()
        #expect(line.hasPrefix("Imported "))
        let imported = try #require(try await b.snippets().first { $0.name == "Work intro" })
        #expect(imported.account == nil, "a shared snippet is for every account")
        let signOff = try #require(try await b.snippets().first { $0.name == "Sign-off" })
        #expect(signOff.shortcut == "so" && signOff.variables == [SnippetVariableInfo(name: "x", defaultValue: "y")])
    }

    @Test func importReplacesByNameKeepsTheAccountAndNeverDeletes() async throws {
        let a = SettingsFixture()
        try await add(a, "Sign-off", shortcut: "so", body: "New text.")
        let file = try await SnippetTransferModel(environment: a.env).export()
        let b = SettingsFixture()
        try await add(b, "sign-off", shortcut: "bye", account: b.work, body: "Old text.")
        try await add(b, "Only here", body: "Stays.")
        let model = SnippetTransferModel(environment: b.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.toReplace >= 1)
        await model.applyImport()
        let snippets = try await b.snippets()
        let replaced = snippets.filter { $0.name.lowercased() == "sign-off" }
        #expect(replaced.count == 1, "replaced, not duplicated")
        #expect(replaced.first?.account == b.work && SnippetBody.plain(fromHTML: replaced.first?.bodyHTML ?? "") == "New text.")
        #expect(snippets.contains { $0.name == "Only here" }, "never deletes")
    }

    @Test func aClashingShortcutIsLeftOff() {
        let existing = [SnippetInfo(id: "s1", account: nil, name: "Thanks", shortcut: "ty", subject: nil, bodyHTML: "Thanks",
                                    variables: [], useCount: 0)]
        let file = [SnippetBundle.Snippet(name: "Thank you", shortcut: ";;TY", subject: nil, bodyHTML: "Thank you", variables: []),
                    SnippetBundle.Snippet(name: "Thanks", shortcut: "ty", subject: nil, bodyHTML: "Thanks!", variables: []),
                    SnippetBundle.Snippet(name: "  ", shortcut: nil, subject: nil, bodyHTML: "no name", variables: []),
                    SnippetBundle.Snippet(name: "thanks", shortcut: nil, subject: nil, bodyHTML: "second of a name", variables: [])]
        let usable = SnippetTransferModel.usable(file)
        #expect(usable.map(\.name) == ["Thank you", "Thanks"], "blank names and repeated names are dropped")
        let plans = SnippetTransferModel.plan(usable, existing: existing)
        #expect(plans[0].match == nil && plans[0].dropsShortcut, "ty is another snippet's")
        #expect(plans[1].match?.id == "s1" && !plans[1].dropsShortcut, "its own shortcut")
    }

    @Test func readOnlyPreviewsAndRefusesAndOtherFilesAreRefusedInWords() async throws {
        let a = SettingsFixture()
        try await add(a, "Sign-off", shortcut: "so")
        let file = try await SnippetTransferModel(environment: a.env).export()
        let readOnly = SettingsFixture(safeMode: .readOnly)
        let before = try await readOnly.snippets()
        let model = SnippetTransferModel(environment: readOnly.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.storedItemsNote != nil)
        let line = await model.applyImport()
        #expect(line == preview.storedItemsNote)
        #expect(try await readOnly.snippets() == before, "nothing stored in read-only")

        let settingsFile = try await SettingsTransferModel(environment: a.env).export()
        await #expect(throws: SnippetTransferError.notASnippetsFile) { try await model.prepareImport(settingsFile) }
        await #expect(throws: SettingsTransferError.notASettingsFile) {
            try await SettingsTransferModel(environment: a.env).prepareImport(file)
        }
        let newer = Data(#"{"format":"openhuman-snippets","version":9,"snippets":[]}"#.utf8)
        await #expect(throws: SnippetTransferError.newerVersion) { try await model.prepareImport(newer) }
        #expect(SnippetTransferError.notASnippetsFile.description == "That isn't a Mail snippets file.")
    }
}
