import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite struct PromptsSettingsModelTests {
    private func model(tester: PromptsSettingsModel.Tester? = nil) -> PromptsSettingsModel {
        let registry = PromptRegistry(provider: PromptLibraryProvider(bundled: .standard),
                                      store: InMemoryPromptOverrideStore(), now: { fixedNow })
        return PromptsSettingsModel(registry: registry, tester: tester)
    }

    @Test func listsEveryPromptWithItsVersion() async throws {
        let model = model()
        await model.load()
        #expect(model.rows.map(\.id) == PromptCatalog.ids)
        #expect(model.rows.count == PromptLibrary.standard.templates.count)
        let line = try #require(model.rows.first { $0.id == "summarize.line" })
        #expect(line.version == 3 && line.badge == nil && line.revisionCount == 0)
        #expect(model.sections.first?.group == .summaries && model.sections.flatMap(\.rows).count == model.rows.count)
    }

    @Test func saveMakesARevisionResetKeepsTheHistoryRevertCopies() async throws {
        let model = model()
        await model.select("summarize.line")
        #expect(model.draft == model.originalText && !model.hasChanges && !model.canSave)
        #expect(model.identity == "summarize.line@3")

        model.draft = "Say what it is about in one sentence."
        model.note = "plainer"
        #expect(model.canSave)
        await model.save()
        #expect(model.selected?.badge == "Edited · r1" && model.selected?.revisionCount == 1)
        #expect(model.history.map(\.revision) == [1] && model.history.first?.note == "plainer")
        #expect(model.identity.hasPrefix("summarize.line@3+r1 ("))
        #expect(!model.hasChanges)
        #expect(model.changes.contains(.init(.added, "Say what it is about in one sentence.")))

        await model.resetToOriginal()
        #expect(model.selected?.badge == nil && model.draft == model.originalText)
        #expect(model.history.count == 1, "reset keeps the history")

        await model.revert(to: 1)
        #expect(model.selected?.badge == "Edited · r2" && model.draft == "Say what it is about in one sentence.")
        #expect(model.history.first?.origin == .revert)
    }

    @Test func aRefusedTextCannotBeSavedAndWarningsDoNotBlock() async throws {
        let model = model()
        await model.select("autolabel.classify")
        model.draft = "Pick one: {{category}}"
        #expect(!model.canSave && model.check.problems == [.unknownSlot("category")])
        await model.save()
        #expect(model.history.isEmpty)
        model.draft = "Pick the one category that fits."
        #expect(model.canSave && model.check.warnings == [.noJSONForm])
        #expect(!PromptsSettingsModel.message(PromptWarning.noJSONForm).isEmpty)
    }

    @Test func aLinkOpensTheEditorOrSaysThePromptIsMissing() async throws {
        let model = model()
        await model.open(promptID: "autolabel.classify")
        #expect(model.selectedID == "autolabel.classify" && model.draft == model.originalText)
        #expect(model.deepLink == "openhuman://settings/ai/prompts/autolabel.classify")
        await model.open(promptID: "no.such.prompt")
        #expect(model.selectedID == nil && model.missingPrompt == "no.such.prompt")
        await model.open(promptID: "")
        #expect(model.selectedID == nil && model.missingPrompt == nil)
    }

    @Test func testOnThisThreadSendsTheUnsavedDraftOnly() async throws {
        @MainActor final class Asked { var drafts: [String?] = [] }
        let asked = Asked()
        let model = model(tester: { info, draft in
            asked.drafts.append(draft)
            return PromptTestResult(output: "ok", promptIdentity: info.id, providerName: "Fake", subject: "Lunch")
        })
        await model.select("summarize.line")
        #expect(model.canTest)
        await model.runTest()
        model.draft = "Mine."
        await model.runTest()
        #expect(asked.drafts == [nil, "Mine."])
        #expect(model.test == .done(PromptTestResult(output: "ok", promptIdentity: "summarize.line", providerName: "Fake",
                                                     subject: "Lunch")))
        #expect(model.history.isEmpty, "a test saves nothing")
        await model.select("rewrite.instruct")
        #expect(!model.canTest)
    }
}

@MainActor
@Suite struct PromptTestOnThreadTests {
    nonisolated static let draftAnswer = "The draft line."
    nonisolated static let defaultAnswer = "The default line."

    @Test func runsTheDraftOnTheConversationAndStoresNothing() async throws {
        let scripted = ScriptedProvider { request, _ in
            .text(request.system.hasSuffix("Mine: one line.") ? Self.draftAnswer : Self.defaultAnswer)
        }
        let f = AIFixture(providers: [scripted])
        let thread = try #require(try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil,
                                                               limit: 5).rows.first?.id)
        let info = try #require(PromptCatalog.entry(PromptName.summarizeLine.rawValue))

        let draft = try await f.center.testPrompt(info, draft: "Mine: one line.", on: thread)
        #expect(draft.output == Self.draftAnswer && draft.promptIdentity.hasPrefix("summarize.line@3+draft"))
        let plain = try await f.center.testPrompt(info, draft: nil, on: thread)
        #expect(plain.output == Self.defaultAnswer && plain.promptIdentity == "summarize.line@3")
        #expect(scripted.requests.count == 2)
        #expect(PromptLibraryProvider.shared.overrides[info.id] == nil, "a draft never becomes an override")
        let stored = await (f.center.cache as? InMemoryAIResultCache)?.count
        #expect(stored == 0, "a test run stores no answer")
    }

    @Test func aPromptWithoutAThreadTestSaysSo() async throws {
        let f = AIFixture()
        let thread = try #require(try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil,
                                                               limit: 1).rows.first?.id)
        let info = try #require(PromptCatalog.entry(PromptName.rewrite.rawValue))
        await #expect(throws: PromptTestError.notTestable) { try await f.center.testPrompt(info, draft: nil, on: thread) }
    }

    @Test func theAutoLabelInputIsTheSubjectNewestSenderAndAnExcerpt() {
        let message = AIMessageInput(messageKey: "m2", from: "Ana <ana@example.com>", date: fixedNow,
                                     bodyText: String(repeating: "x", count: 5_000))
        let input = AIThreadInput(threadKey: "t1", subject: "Lunch on Friday", messages: [message])
        let parts = AICenter.classificationInput(input)
        #expect(parts.subject.text == "Lunch on Friday" && parts.sender.text == "Ana <ana@example.com>")
        #expect(parts.excerpt.text.count == AIPolicy.classifyExcerptCharacters && parts.excerpt.id == "m2")
    }
}

@MainActor
@Suite struct ComposerPresetPromptTests {
    @Test func everyPresetReadsItsPromptFile() throws {
        for preset in AIComposerModel.presets + [AIComposerModel.voicePreset] {
            let text = try PromptLibrary.standard.instruction(preset.prompt)
            #expect(!text.isEmpty)
            #expect(preset.instruction == (preset.completesInput ? text + " " : text))
            #expect(preset.prompt.role == .instruction && preset.prompt.task == .rewrite)
        }
        #expect(Set((AIComposerModel.presets + [AIComposerModel.voicePreset]).map(\.prompt)).count == 9)
    }
}

@MainActor
@Suite struct SettingsLinkRouteTests {
    @MainActor final class Opened { var count = 0 }

    @Test func aSettingsLinkOnlyNavigates() {
        let f = AIFixture()
        let navigator = f.env.settingsNavigator
        let opened = Opened()
        navigator.openWindow = { opened.count += 1 }
        #expect(f.router.route(.settings(.aiPrompts(promptID: "autolabel.classify"))).handled)
        #expect(opened.count == 1)
        #expect(navigator.takeRequestedPage() == "ai" && navigator.takeRequestedPrompt() == "autolabel.classify")
        #expect(f.router.route(.settings(.aiPrompts(promptID: nil))).handled)
        #expect(navigator.takeRequestedPrompt() == "")
        #expect(f.router.route(.settings(.page("importance"))).handled)
        #expect(navigator.takeRequestedPage() == "importance" && navigator.takeRequestedPrompt() == nil)
        navigator.openWindow = nil
        #expect(!f.router.route(.settings(.page("ai"))).handled, "nothing can open the window")
        #expect(DeepLinkRouter.name(.settings(.page("ai"))) == "settings")
    }
}
