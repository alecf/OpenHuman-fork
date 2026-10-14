import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct PrivacySettingsTests {
    @Test func remoteImagesDefaultToBlockPerAccountAndTheAllowlistIsNormalized() async throws {
        let f = SettingsFixture()
        let model = PrivacySettingsModel(environment: f.env)
        model.start()
        await eventually { model.policy != nil }
        #expect(model.policy?.value == .block)
        await model.setPolicy(.ask)
        #expect(try await f.store.get(AppSettings.remoteImages(f.work)) == .ask)
        #expect(try await f.store.get(AppSettings.remoteImages(f.personal)) == .block, "per account")
        model.newSender = " News@Example.COM "
        await model.addSender()
        model.newSender = "acme.example"
        await model.addSender()
        #expect(try await f.store.get(AppSettings.remoteImageSenders(f.work)) == ["@acme.example", "news@example.com"])
        model.newSender = "not an address"
        await model.addSender()
        #expect(model.errorMessage != nil)
        await model.removeSender("@acme.example")
        #expect(try await f.store.get(AppSettings.remoteImageSenders(f.work)) == ["news@example.com"])
        #expect(PrivacySettingsModel.normalizedSender("@x") == nil && PrivacySettingsModel.normalizedSender("a@b") == nil)
    }

    @Test func privacyChoicesStillWorkInReadOnlySafeMode() async throws {
        let f = SettingsFixture(safeMode: .readOnly)
        let model = PrivacySettingsModel(environment: f.env)
        model.start()
        await eventually { model.policy != nil }
        await model.setPolicy(.allow)
        #expect(try await f.store.get(AppSettings.remoteImages(f.work)) == .allow)
    }
}

@MainActor
struct ShortcutsSettingsTests {
    @Test func theListIsReadOnlySearchableAndOmitsModulesThatAreOff() {
        let on = ShortcutsSettingsModel(environment: SettingsFixture().env)
        #expect(on.sections.flatMap(\.lines).contains { $0.title == "Mark done" })
        on.searchText = "mark done"
        #expect(on.sections.flatMap(\.lines).allSatisfy { $0.title.lowercased().contains("mark done") || $0.keys.contains { $0.lowercased() == "mark done" } })
        on.searchText = ""
        let off = ShortcutsSettingsModel(environment: SettingsFixture(flags: FeatureFlags().with(.snooze, false)).env)
        let titles: (ShortcutsSettingsModel) -> Set<String> = { Set($0.sections.flatMap(\.lines).map(\.title)) }
        #expect(titles(on).count > titles(off).count)
        #expect(on.cheatSheetText.hasPrefix("OpenHuman Mail: keyboard shortcuts") && on.cheatSheetText.contains("Mark done"))
    }
}

@MainActor
struct SettingsTransferTests {
    private func configure(_ f: SettingsFixture) async throws {
        let model = SplitSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil }
        let commands = f.store
        _ = try await commands.upsertSplit(SplitDefinition(account: f.work, name: "Clients", ruleText: "from:(@example.com)"))
        _ = try await commands.upsertSnippet(SnippetInfo(name: "Sign-off", shortcut: "so", bodyHTML: "Best,<br>R",
                                                         variables: [SnippetVariableInfo(name: "x", defaultValue: "y")]))
        try await f.store.set(AppSettings.undoSendSeconds, 30)
        try await f.store.set(AppSettings.schedulerReminders, false)
        try await f.store.set(AppSettings.remoteImages(f.work), .ask)
        try await f.store.set(AppSettings.remoteImageSenders(f.work), ["@acme.example"])
        try await f.store.set(ComposeSettings.replyFrom(f.personal), .lastUsedOnThread)
    }

    @Test func exportThenImportIntoAnEmptyFakeStoreReproducesSplitsSnippetsAndSettings() async throws {
        let a = SettingsFixture()
        try await configure(a)
        let file = try await SettingsTransferModel(environment: a.env).export()
        let b = SettingsFixture()
        let before = try await b.snippets().count
        let model = SettingsTransferModel(environment: b.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.splitsToAdd >= 1 && preview.snippetsToAdd >= 1 && preview.settingsToApply >= 5)
        #expect(preview.accountsSkipped == 0 && preview.storedItemsNote == nil)
        #expect(try await b.store.get(AppSettings.undoSendSeconds) == 10, "preview writes nothing")
        await model.applyImport()
        #expect(model.message == "Settings imported.")
        #expect(try await b.splits(b.work).contains { $0.name == "Clients" && $0.ruleText == "from:(@example.com)" })
        let snippet = try #require(try await b.snippets().first { $0.name == "Sign-off" })
        #expect(snippet.shortcut == "so" && snippet.variables == [SnippetVariableInfo(name: "x", defaultValue: "y")])
        #expect(try await b.snippets().count == before + 1)
        #expect(try await b.store.get(AppSettings.undoSendSeconds) == 30)
        #expect(try await b.store.get(AppSettings.schedulerReminders) == false)
        #expect(try await b.store.get(AppSettings.remoteImages(b.work)) == .ask)
        #expect(try await b.store.get(AppSettings.remoteImageSenders(b.work)) == ["@acme.example"])
        #expect(try await b.store.get(ComposeSettings.replyFrom(b.personal)) == .lastUsedOnThread)
        let again = try await SettingsTransferModel(environment: b.env).export()
        let left = try JSONDecoder().decode(SettingsBundle.self, from: file)
        let right = try JSONDecoder().decode(SettingsBundle.self, from: again)
        #expect(left == right)
    }

    @Test func importReplacesByNameAndNeverDeletes() async throws {
        let a = SettingsFixture()
        try await configure(a)
        let file = try await SettingsTransferModel(environment: a.env).export()
        let b = SettingsFixture()
        _ = try await b.store.upsertSplit(SplitDefinition(account: b.work, name: "clients", ruleText: "is:unread"))
        _ = try await b.store.upsertSplit(SplitDefinition(account: b.work, name: "Only here", ruleText: "is:starred"))
        let model = SettingsTransferModel(environment: b.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.splitsToReplace >= 1 && preview.splitsToAdd == 0)
        await model.applyImport()
        let splits = try await b.splits(b.work)
        #expect(splits.filter { $0.name.lowercased() == "clients" }.count == 1, "replaced, not duplicated")
        #expect(splits.first { $0.name.lowercased() == "clients" }?.ruleText == "from:(@example.com)")
        #expect(splits.contains { $0.name == "Only here" }, "never deletes")
    }

    @Test func aFileThatIsNotOursOrIsNewerIsRefusedInWords() async throws {
        let model = SettingsTransferModel(environment: SettingsFixture().env)
        await #expect(throws: SettingsTransferError.notASettingsFile) { try await model.prepareImport(Data("{}".utf8)) }
        await #expect(throws: SettingsTransferError.notASettingsFile) { try await model.prepareImport(Data("garbage".utf8)) }
        let newer = Data(#"{"format":"openhuman-settings","version":99,"global":{},"accounts":[],"snippets":[]}"#.utf8)
        await #expect(throws: SettingsTransferError.newerVersion) { try await model.prepareImport(newer) }
        #expect(SettingsTransferError.notASettingsFile.description == "That isn't a Mail settings file.")
    }

    @Test func anUndoSendTimeOutsideTheSettingsRangeIsSkippedNotImported() async throws {
        let f = SettingsFixture()
        try await f.store.set(AppSettings.undoSendSeconds, 20)
        func file(_ seconds: String) -> Data {
            Data(#"{"format":"openhuman-settings","version":1,"global":{"undoSendSeconds":\#(seconds),"schedulerReminders":false},"accounts":[],"snippets":[]}"#.utf8)
        }
        for bad in ["9223372036854775807", "-9223372036854775808", "61", "-1"] {
            let model = SettingsTransferModel(environment: f.env)
            let preview = try await model.prepareImport(file(bad))
            #expect(preview.settingsToApply == 1 && preview.settingsSkipped == 1, "\(bad)")
            #expect(await model.applyImport() == "Settings imported.")
            #expect(try await f.store.get(AppSettings.undoSendSeconds) == 20, "\(bad)")
        }
        #expect(try await f.store.get(AppSettings.schedulerReminders) == false)
        let model = SettingsTransferModel(environment: f.env)
        #expect(try await model.prepareImport(file("60")).settingsSkipped == 0)
        await model.applyImport()
        #expect(try await f.store.get(AppSettings.undoSendSeconds) == 60)
        try await f.store.set(AppSettings.undoSendSeconds, Int.max)
        let exported = try JSONDecoder().decode(SettingsBundle.self, from: try await SettingsTransferModel(environment: f.env).export())
        #expect(exported.global.undoSendSeconds == nil)
    }

    @Test func accountsThisMacDoesNotHaveAreSkippedAndReadOnlySkipsStoredItems() async throws {
        let a = SettingsFixture()
        try await configure(a)
        let file = try await SettingsTransferModel(environment: a.env).export()
        let readOnly = SettingsFixture(safeMode: .readOnly)
        let model = SettingsTransferModel(environment: readOnly.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.splitsToAdd == 0 && preview.snippetsToAdd == 0 && preview.storedItemsNote != nil)
        #expect(preview.settingsToApply > 0, "local settings still import")
        await model.applyImport()
        #expect(try await readOnly.store.get(AppSettings.undoSendSeconds) == 30)
        #expect(try await readOnly.splits(readOnly.work).allSatisfy { $0.name != "Clients" })
        var json = try #require(String(data: file, encoding: .utf8))
        for account in try await a.accounts() { json = json.replacingOccurrences(of: account.email, with: "someone.else@elsewhere.example") }
        let other = SettingsTransferModel(environment: SettingsFixture().env)
        #expect(try await other.prepareImport(Data(json.utf8)).accountsSkipped == 2)
    }

    @Test func theExportHoldsNoTokensClientOrSafetyKeysAndNoMail() async throws {
        let a = SettingsFixture()
        try await configure(a)
        try await a.store.set(AppSettings.cliReadonlyDefault, true)
        let text = String(decoding: try await SettingsTransferModel(environment: a.env).export(), as: UTF8.self)
        for forbidden in ["cli.", "cliReadonly", "token", "secret", "client_id", "subject\":\"Re", "oauth"] {
            #expect(!text.lowercased().contains(forbidden.lowercased()), "\(forbidden) leaked into the export")
        }
        #expect(text.contains("\"format\" : \"openhuman-settings\""))
    }
}
