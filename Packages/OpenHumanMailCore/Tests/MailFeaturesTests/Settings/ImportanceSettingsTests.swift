import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct ImportanceSettingsTests {
    private func model(_ f: SettingsFixture) async -> ImportanceSettingsModel {
        let model = ImportanceSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil && model.hasLoaded }
        return model
    }

    private func port(_ f: SettingsFixture) -> FakeImportanceRules { f.env.importance as! FakeImportanceRules }

    @Test func theModuleRegistersThePageTheShellDraws() {
        let f = SettingsFixture()
        #expect(ImportanceSettingsModel.pageID == "importance")
        #expect(f.env.modules.settingsPages.contains { $0.id == ImportanceSettingsModel.pageID && $0.title == "Importance & labels" })
    }

    @Test func rulesAreGroupedBySpecificityAndSaidInWords() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        #expect(model.groups.isEmpty)
        #expect(ImportanceSettingsModel.emptyText.contains("(+)") && ImportanceSettingsModel.emptyText.contains("(-)"))
        let account = try #require(model.account)
        let rules = port(f)
        _ = try await rules.apply(ImportanceChange(kind: .keyword, account: account, value: "Invoice"))
        _ = try await rules.apply(ImportanceChange(kind: .neverDomain, account: account, value: "example.com"))
        _ = try await rules.apply(ImportanceChange(kind: .alwaysSender, account: account, value: "alice@example.com"))
        _ = try await rules.apply(ImportanceChange(kind: .label, account: account, value: "Clients", effect: .neverImportant))
        _ = try await rules.apply(ImportanceChange(kind: .notPitch, account: account, value: "bob@example.org"))
        await eventually { model.rules.count == 5 }
        #expect(model.groups.map(\.title) == ["Senders", "Domains", "Gmail labels", "Keywords", "Kept out of splits"])
        #expect(model.groups.flatMap(\.rows).map(\.title) == [
            "Always important from alice@example.com", "Never important from example.com",
            "Never important with the label Clients", "Always important when it mentions \u{201C}invoice\u{201D}",
            "Not a pitch: bob@example.org",
        ])
        #expect(model.groups[0].rows.first?.detail == "Exception to the rule for example.com")
        #expect(model.groups[1].rows.first?.detail == "alice@example.com is an exception")
        #expect(model.groups[2].rows.first?.detail == nil)
        #expect(model.groups.last?.footnote == ImportanceSettingsModel.exemptionsNote)
        #expect(model.groups.dropLast().allSatisfy { $0.rows.allSatisfy(\.isEditable) })
        #expect(model.groups.last?.rows.first?.isEditable == false, "split exceptions are deleted, not edited")
    }

    @Test func addEditDeleteAndUndo() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        #expect(model.canEdit && model.editNote == nil)
        model.beginAdd()
        model.draft?.match = .domain
        model.draft?.effect = .neverImportant
        model.draft?.value = "  @Example.COM. "
        #expect(model.draftCheck?.text == "Never important from example.com" && model.draftCheck?.isProblem == false)
        #expect(model.canSave)
        await model.save()
        #expect(model.draft == nil && model.errorMessage == nil)
        await eventually { model.rules.count == 1 }
        #expect(model.rules.first?.kind == .neverDomain && model.rules.first?.value == "example.com")
        #expect(model.lastChange?.title == "Added rule: Never important from example.com")
        #expect(f.env.undo?.stack.last?.undoer != nil, "on the window's undo stack, undone through the importance port")

        let row = try #require(model.groups.first?.rows.first)
        model.beginEdit(row)
        #expect(model.draft?.id == row.id && model.draft?.match == .domain && model.draft?.value == "example.com")
        model.draft?.effect = .important
        await model.save()
        await eventually { model.rules.first?.kind == .alwaysDomain }
        #expect(model.rules.map(\.id) == [row.id])
        #expect(model.lastChange?.title == "Changed rule: Always important from example.com")

        let edited = try #require(model.groups.first?.rows.first)
        await model.delete(edited)
        await eventually { model.rules.isEmpty }
        #expect(model.canUndoLastChange)
        await model.undoLastChange()
        await eventually { model.rules.count == 1 }
        #expect(model.rules.first?.kind == .alwaysDomain && model.rules.first?.id == row.id)
        #expect(model.lastChange == nil && !model.canUndoLastChange && model.errorMessage == nil)
    }

    @Test func undoInTheMailWindowTakesThePagesUndoAway() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        model.beginAdd(.keyword)
        model.draft?.value = "Quarterly report"
        await model.save()
        await eventually { model.rules.count == 1 }
        #expect(model.rules.first?.value == "quarterly report")
        #expect(model.canUndoLastChange)
        await f.env.undo?.undoLast()
        await eventually { model.rules.isEmpty }
        #expect(!model.canUndoLastChange, "nothing left for the page to undo")
    }

    @Test func aBadValueGetsASentenceAndADuplicateIsRefused() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        model.beginAdd(.sender)
        model.draft?.value = "not an address"
        #expect(model.draftCheck?.isProblem == true)
        await model.save()
        #expect(model.errorMessage == "Enter an address like name@example.com.")
        #expect(model.rules.isEmpty && model.draft != nil, "the editor stays open with the text")
        model.draft?.value = "Dana Ruiz <Dana@Example.com>"
        await model.save()
        await eventually { model.rules.count == 1 }
        #expect(model.rules.first?.value == "dana@example.com")
        model.beginAdd(.sender)
        model.draft?.value = "dana@example.com"
        await model.save()
        #expect(model.errorMessage == "That rule is already in the list.")
        #expect(model.rules.count == 1)
        model.cancelEdit()
        #expect(model.draft == nil && model.errorMessage == nil)
    }

    @Test func valuesAreCheckedWithTheStoresRules() {
        #expect(ImportanceSettingsModel.normalized("Dana Ruiz <Dana@Example.com>", for: .sender) == "dana@example.com")
        #expect(ImportanceSettingsModel.normalized("mailto:dana@example.com", for: .sender) == "dana@example.com")
        #expect(ImportanceSettingsModel.normalized("dana", for: .sender) == nil)
        #expect(ImportanceSettingsModel.normalized("@dana", for: .sender) == nil)
        #expect(ImportanceSettingsModel.normalized("@Example.com.", for: .domain) == "example.com")
        #expect(ImportanceSettingsModel.normalized("example", for: .domain) == nil)
        #expect(ImportanceSettingsModel.normalized("a@example.com", for: .domain) == nil)
        #expect(ImportanceSettingsModel.normalized("example..com", for: .domain) == nil)
        #expect(ImportanceSettingsModel.normalized("  Quarterly \n  Report ", for: .keyword) == "quarterly report")
        #expect(ImportanceSettingsModel.normalized(String(repeating: "x", count: 201), for: .keyword) == nil)
        #expect(ImportanceSettingsModel.normalized(" Clients/2026 ", for: .label) == "Clients/2026")
        #expect(ImportanceSettingsModel.normalized("   ", for: .label) == nil)
        #expect(ImportanceSettingsModel.normalized("keyword:invoice", for: .matcher) == nil, "add-on rules are not typed here")
    }


    @Test func withoutAWritePortThePageKeepsTheUndoToken() async throws {
        let store = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let rules = FakeImportanceRules()
        let env = AppEnvironment(data: store, isFake: true, importance: rules, featureFlags: FeatureFlags())
        #expect(env.undo == nil)
        let model = ImportanceSettingsModel(environment: env)
        model.start()
        await eventually { model.account != nil && model.hasLoaded }
        model.beginAdd(.label)
        model.draft?.value = "Clients"
        await model.save()
        await eventually { model.rules.count == 1 }
        #expect(model.rules.first?.kind == .label && model.rules.first?.value == "Clients")
        #expect(model.canUndoLastChange)
        await model.undoLastChange()
        await eventually { model.rules.isEmpty }
        #expect(model.errorMessage == nil && model.lastChange == nil)
    }

    @Test func withoutAnImportancePortThePageSaysSo() async throws {
        let store = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let env = AppEnvironment(data: store, commands: store, isFake: true, featureFlags: FeatureFlags())
        let model = ImportanceSettingsModel(environment: env)
        model.start()
        await eventually { model.account != nil }
        #expect(!model.canEdit && !model.hasLoaded)
        #expect(model.editNote == "Importance rules aren't available with this mail source.")
    }

    @Test func eachAccountHasItsOwnRules() async throws {
        let f = SettingsFixture()
        let model = await model(f)
        let first = try #require(model.account)
        let other = try #require(model.accounts.first { $0.id != first }?.id)
        _ = try await port(f).apply(ImportanceChange(kind: .alwaysDomain, account: first, value: "example.com"))
        await eventually { model.rules.count == 1 }
        model.beginAdd()
        model.account = other
        await eventually { model.account == other && model.hasLoaded }
        #expect(model.rules.isEmpty && model.draft == nil, "another account's list, and the editor closed")
    }

    @Test func theNotesNameTheRuleThatWins() {
        func info(_ id: String, _ kind: ImportanceRuleKind, _ value: String, effect: ImportanceRuleEffect? = nil,
                  origin: ImportanceRuleOrigin = .user, everyAccount: Bool = false) -> ImportanceRuleInfo {
            ImportanceRuleInfo(id: id, kind: kind, account: AccountID(1), value: value, split: nil, createdAt: fixedNow,
                               effect: effect, origin: origin, appliesToEveryAccount: everyAccount)
        }
        let rows = ImportanceSettingsModel.groups([
            info("1", .alwaysSender, "alice@mail.example.com"),
            info("2", .alwaysSender, "carol@example.com"),
            info("3", .neverDomain, "example.com"),
            info("4", .neverDomain, "mail.example.com"),
            info("5", .alwaysDomain, "example.org", everyAccount: true),
            info("6", .keyword, "invoice", effect: .neverImportant, origin: .ai),
            info("7", .neverSender, "dave@example.org", origin: .ai),
        ]).flatMap(\.rows)
        func detail(_ id: String) -> String? { rows.first { $0.id == id }?.detail }
        #expect(detail("1") == "Exception to the rule for mail.example.com", "the narrowest domain rule")
        #expect(detail("2") == "Exception to the rule for example.com")
        #expect(detail("3") == "2 senders are exceptions")
        #expect(detail("4") == "alice@mail.example.com is an exception")
        #expect(detail("5") == "dave@example.org is an exception · All accounts")
        #expect(detail("6") == "Suggested by AI")
        #expect(detail("7") == "Exception to the rule for example.org · Suggested by AI")
        #expect(rows.first { $0.id == "6" }?.title == "Never important when it mentions \u{201C}invoice\u{201D}")
        #expect(ImportanceSettingsModel.isInDomain("bob@example.com.evil", "example.com") == false)
        #expect(ImportanceSettingsModel.isInDomain("bob@notexample.com", "example.com") == false)
        #expect(ImportanceSettingsModel.title(info("8", .excludeFromSplit, "eve@example.net"), splitName: "Pitches")
            == "Not in Pitches: eve@example.net")
        #expect(ImportanceSettingsModel.title(info("9", .excludeFromSplit, "eve@example.net")) == "Not in any split: eve@example.net")
    }
}
