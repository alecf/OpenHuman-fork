import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct SplitSettingsTests {
    private func model(_ f: SettingsFixture) async -> SplitSettingsModel {
        let model = SplitSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil && !model.splits.isEmpty }
        return model
    }

    @Test func theSeededImportantSplitIsListedAndANewSplitAppearsAsATab() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        #expect(model.splits.first?.name == "Important" && model.splits.first?.ruleText == "is:important")
        #expect(SplitSettingsModel.otherNote == "Everything not in a split")
        model.beginAdd()
        model.draft?.name = "Clients"
        model.draft?.ruleText = "from:(@example.com)"
        #expect(model.canSave)
        await model.save()
        #expect(model.draft == nil && model.errorMessage == nil)
        await eventually { model.splits.contains { $0.name == "Clients" } }
        #expect(try await f.splits(model.account!).map(\.name).contains("Clients"))
    }

    @Test func theLivePreviewCountsMatchesAndNamesABadRule() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        model.beginAdd()
        model.draft?.ruleText = "is:important"
        model.updatePreview()
        await eventually { model.preview?.hasPrefix("Matches") == true }
        #expect(model.preview != "Matches 0 conversations")
        model.draft?.ruleText = "from:(nobody-at-all@nowhere.invalid)"
        model.updatePreview()
        await eventually { model.preview == "Matches 0 conversations" }
        #expect(SplitSettingsModel.previewText(count: 1, more: false) == "Matches 1 conversation")
        #expect(SplitSettingsModel.previewText(count: 500, more: true) == "Matches 500+ conversations")
        model.cancelEdit()
        #expect(model.preview == nil)
    }

    @Test func editDeleteAndReorder() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let initial = model.splits.count
        for (name, rule) in [("Alpha", "from:(@example.com)"), ("Beta", "from:(@example.org)")] {
            model.beginAdd()
            model.draft?.name = name
            model.draft?.ruleText = rule
            await model.save()
        }
        await eventually { model.splits.count == initial + 2 }
        let beta = try #require(model.splits.first { $0.name == "Beta" })
        model.beginEdit(beta)
        model.draft?.name = "Beta 2"
        await model.save()
        await eventually { model.splits.contains { $0.name == "Beta 2" } }
        let before = model.splits.map(\.name)
        await model.move(from: IndexSet(integer: model.splits.count - 1), to: 0)
        await eventually { model.splits.map(\.name) != before }
        #expect(model.splits.first?.name == "Beta 2")
        let alpha = try #require(model.splits.first { $0.name == "Alpha" })
        await model.delete(alpha)
        await eventually { !model.splits.contains { $0.name == "Alpha" } }
        #expect(model.splits.count == initial + 1)
    }

    @Test func aDuplicateNameIsRefusedInWords() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        model.beginAdd()
        model.draft?.name = "important"
        model.draft?.ruleText = "is:unread"
        await model.save()
        #expect(model.errorMessage?.contains("exists") == true)
        #expect(model.draft != nil, "the editor stays open")
    }

    @Test func aPresetFillsTheEditorWithItsCountAndNeverAddsBySelf() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let initial = model.splits.count
        let calendar = try #require(model.presets.first { $0.id == "events" })
        #expect(model.existingSplit(for: calendar) == nil)
        model.beginPreset(calendar)
        #expect(model.draft?.name == "Events" && model.draft?.ruleText == calendar.ruleText && model.draft?.id == nil)
        await eventually { model.preview?.hasPrefix("Matches") == true }
        #expect(model.preview != "Matches 0 conversations", "the rich corpus has calendar invites")
        #expect(model.splits.count == initial, "choosing a preset adds nothing")
        model.cancelEdit()
        #expect(model.splits.count == initial && model.draft == nil)
        model.beginPreset(calendar)
        await model.save()
        await eventually { model.splits.contains { $0.name == "Events" } }
        #expect(model.existingSplit(for: calendar) != nil)
        model.beginPreset(calendar)
        await model.save()
        #expect(model.errorMessage?.contains("exists") == true)
    }

    @Test func presetsAreRefusedWithoutAWritePortWithTheReason() async throws {
        let f = SettingsFixture(writePort: false)
        let model = await model(f)
        let initial = try await f.splits(f.work).count
        let github = try #require(model.presets.first { $0.id == "github" })
        model.beginPreset(github)
        #expect(model.draft == nil, "the editor does not open")
        #expect(model.presetsUnavailableReason == "Editing isn't available here.")
        #expect(try await f.splits(f.work).count == initial)
    }

    @Test func thePresetListIsTheDocumentedOne() {
        #expect(SplitPresets.all.map(\.name) == ["Events", "Asana", "ClickUp", "GitHub", "Linear", "Notion",
                                                 "Slack notifications", "Newsletters (List-Unsubscribe)"])
        #expect(Set(SplitPresets.all.map(\.id)).count == SplitPresets.all.count)
        #expect(SplitPresets.all.map(\.ruleText) == ["is:event", "from:@", "from:@", "from:@github.com",
                                                     "from:@linear.app", "from:@",
                                                     "from:@slack.com OR from:@slack-mail.com",
                                                     "list:. OR category:promotions"])
        #expect(SplitPresets.all.filter(\.needsDomain).map(\.id) == ["asana", "clickup", "notion"])
        for preset in SplitPresets.all {
            #expect(preset.needsDomain == (preset.ruleText == "from:@"), Comment(rawValue: preset.id))
        }
    }

    @Test func theGitHubPresetTakesTheWholeDomainAndOldRulesUpgradeOnlyWhenUnedited() {
        #expect(SplitPresets.githubRuleText == "from:@github.com")
        #expect(SplitPresets.upgradedRuleText(for: "from:notifications@github.com") == "from:@github.com")
        #expect(SplitPresets.upgradedRuleText(for: "  From:Notifications@GitHub.com ") == "from:@github.com")
        #expect(SplitPresets.upgradedRuleText(for: "from:notifications@github.com OR is:starred") == nil)
        #expect(SplitPresets.upgradedRuleText(for: "from:@github.com") == nil)
        #expect(SplitPresets.upgradedRuleText(for: "from:notifications@linear.app") == "from:@linear.app")
    }

    @Test func aSplitStillHoldingTheOldGitHubRuleIsUpgradedAndAnEditedOneIsNot() async throws {
        let f = SettingsFixture()
        _ = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "GitHub", ruleText: "from:notifications@github.com"))
        _ = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "Mine", ruleText: "from:notifications@github.com OR is:starred"))
        let model = await model(f)
        await eventually { model.splits.first { $0.name == "GitHub" }?.ruleText == "from:@github.com" }
        #expect(model.splits.first { $0.name == "Mine" }?.ruleText == "from:notifications@github.com OR is:starred")
    }

    @Test func theLaunchMigrationUpgradesUneditedSplitsWithoutOpeningSettings() async throws {
        let f = SettingsFixture()
        _ = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "GitHub", ruleText: "from:notifications@github.com"))
        _ = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "Mine", ruleText: "from:notifications@github.com OR is:starred"))
        let n = await SplitPresetMigration.runAtLaunch(data: f.env.data, commands: f.env.commands,
                                                       availability: SettingsAvailability(environment: f.env))
        #expect(n == 1)
        let rules = Dictionary(uniqueKeysWithValues: try await f.splits(f.work).map { ($0.name, $0.ruleText) })
        #expect(rules["GitHub"] == "from:@github.com")
        #expect(rules["Mine"] == "from:notifications@github.com OR is:starred")
    }

    @Test func theLaunchMigrationWritesNothingWithoutAWritePort() async throws {
        let f = SettingsFixture()
        let ro = SettingsFixture(writePort: false)
        _ = try await f.store.upsertSplit(SplitDefinition(account: f.work, name: "GitHub", ruleText: "from:notifications@github.com"))
        let n = await SplitPresetMigration.runAtLaunch(data: f.env.data, commands: f.env.commands,
                                                       availability: SettingsAvailability(environment: ro.env))
        #expect(n == 0)
        #expect(try await f.splits(f.work).first { $0.name == "GitHub" }?.ruleText == "from:notifications@github.com")
    }

    @Test func anAppPresetOpensTheEditorWithAnEmptyDomainAndIsRefusedUntilADomainIsTyped() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let initial = model.splits.count
        let asana = try #require(model.presets.first { $0.id == "asana" })
        model.beginPreset(asana)
        #expect(model.draft?.ruleText == "from:@" && model.draft?.name == "Asana")
        #expect(model.existingSplit(for: asana) == nil)
        #expect(!model.canSave, "an empty domain is not a rule")
        await model.save()
        #expect(model.splits.count == initial, "nothing was added")
        model.draft?.ruleText = "from:@example.com"
        await model.save()
        await eventually { model.splits.contains { $0.name == "Asana" } }
    }

    @Test func withoutAWritePortEditingIsOffAndSaysWhy() async throws {
        let f = SettingsFixture(writePort: false)
        let model = await model(f)
        let initial = try await f.splits(f.work).count
        #expect(!model.canEdit)
        model.beginAdd()
        #expect(model.draft == nil)
        model.draft = SplitSettingsModel.Draft(id: nil, name: "X", ruleText: "is:unread", enabled: true)
        #expect(!model.canSave)
        await model.save()
        #expect(try await f.splits(f.work).count == initial, "nothing written")
        #expect(model.availability.storedItemsNote == "Editing isn't available here.")
    }
}

@MainActor
struct SnippetSettingsTests {
    private func model(_ f: SettingsFixture) async -> SnippetSettingsModel {
        let model = SnippetSettingsModel(environment: f.env)
        model.start()
        await eventually { !model.snippets.isEmpty }
        return model
    }

    @Test func aNewSnippetIsSavedWithItsVariablesAndIsOfferedByTheShortcut() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        model.beginNew()
        model.draft?.name = "Welcome note"
        model.draft?.shortcut = ";;Welcome"
        model.draft?.subject = "Hello {{first_name}}"
        model.draft?.body = "Hi {{first_name}},\nI'm {{my_name}} from {{company}}.\n\nSee you {{date+3}}."
        #expect(model.variables.map(\.name) == ["first_name", "my_name", "company", "date+3"])
        #expect(model.variables.map(\.isBuiltIn) == [true, true, false, true])
        model.setDefault("Acme", for: "company")
        await model.save()
        #expect(model.draft == nil && model.errorMessage == nil)
        await eventually { model.snippets.contains { $0.name == "Welcome note" } }
        let saved = try #require(model.snippets.first { $0.name == "Welcome note" })
        #expect(saved.shortcut == "welcome")
        #expect(saved.variables == [SnippetVariableInfo(name: "company", defaultValue: "Acme")], "built-ins are not stored")
        #expect(saved.bodyHTML.contains("<br>") && saved.subject == "Hello {{first_name}}")
        let shortcuts = Set(model.snippets.compactMap { $0.shortcut?.lowercased() })
        #expect(SnippetTrigger.detect(in: "x ;;welcome ", caret: 12, shortcuts: shortcuts) != nil)
        model.beginEdit(saved)
        #expect(model.draft?.body.hasPrefix("Hi {{first_name}},\nI'm") == true)
        #expect(model.draft?.defaults["company"] == "Acme")
        model.draft?.name = "Welcome 2"
        await model.save()
        await eventually { model.snippets.contains { $0.name == "Welcome 2" && $0.id == saved.id } }
    }

    @Test func shortcutsAreNormalizedAndACollisionBlocksSaving() async throws {
        #expect(SnippetSettingsModel.normalizedShortcut(" ;;Thanks! ") == "thanks")
        #expect(SnippetSettingsModel.normalizedShortcut(";;") == nil)
        let f = SettingsFixture()
        let model = await model(f)
        let taken = try #require(model.snippets.compactMap(\.shortcut).first)
        model.beginNew()
        model.draft?.name = "Clash"
        model.draft?.body = "x"
        model.draft?.shortcut = ";;" + taken
        #expect(model.shortcutConflict != nil && !model.canSave)
        model.draft?.shortcut = ""
        #expect(model.shortcutConflict == nil && model.canSave)
    }

    @Test func searchFiltersByNameShortcutAndBodyAndDeleteAsksFirst() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let first = try #require(model.snippets.first)
        model.searchText = first.name.lowercased()
        #expect(model.visible.contains { $0.id == first.id })
        model.searchText = "zzzz-no-such-snippet"
        #expect(model.visible.isEmpty)
        model.searchText = ""
        let count = model.snippets.count
        model.askToDelete(first.id)
        model.cancelDelete()
        #expect(model.snippets.count == count, "nothing deleted by asking")
        model.askToDelete(first.id)
        await model.confirmDelete()
        await eventually { model.snippets.count == count - 1 }
        #expect(SnippetSettingsModel.emptyText.hasPrefix("No snippets yet."))
    }

    @Test func bodyConversionRoundTripsAndFlagsFormatting() {
        let html = SnippetBody.html(fromPlain: "a < b & c\nnext")
        #expect(html == "a &lt; b &amp; c<br>next")
        #expect(SnippetBody.plain(fromHTML: html) == "a < b & c\nnext")
        #expect(SnippetBody.isFormatted("<b>bold</b>") && !SnippetBody.isFormatted(html))
    }

    @Test func withoutAWritePortTheListStaysButEditingIsOff() async throws {
        let f = SettingsFixture(writePort: false)
        let model = await model(f)
        #expect(!model.canEdit && !model.snippets.isEmpty)
        model.beginNew()
        #expect(model.draft == nil)
        model.askToDelete(model.snippets[0].id)
        let count = model.snippets.count
        await model.confirmDelete()
        #expect(model.snippets.count == count)
    }
}
