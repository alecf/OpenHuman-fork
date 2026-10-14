import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct PersonalWritingTests {
    private let examples = ["Hi Sam, thanks for the notes. Friday works. Best, R",
                            "Sounds good, see you then.", "  ", "Third one.", "Fourth one is never sent."]

    @Test func preferencesGoWithARewriteAsATrustedContextBlock() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Done.") }
        let settings = AISettings(aboutMe: "I run a small design studio.", writingInstructions: "Short, warm, no exclamation marks.")
        let features = makeFeatures([provider], settings: settings)
        _ = try await collect(features.rewrite("thx", instruction: "Make it polite", context: nil))
        let request = try #require(provider.requests.first)
        let preferences = "About me: I run a small design studio.\nHow I write: Short, warm, no exclamation marks."
        #expect(request.trusted == [TrustedPart(kind: .userInstruction, text: "Make it polite"),
                                    TrustedPart(kind: .userPreferences, text: preferences)])
        #expect(request.renderedInput().contains("<context kind=\"userPreferences\">\(preferences)</context>"))
        #expect(RequestInspector.problems(in: request).isEmpty)
        #expect(request.promptID == PromptID("rewrite.instruct", version: 2))
        #expect(request.system.contains("userPreferences") && request.system.contains("styleExample"))
    }

    @Test func emptyPreferencesAddNothing() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Done.") }
        let features = makeFeatures([provider], settings: AISettings(aboutMe: "  \n", writingInstructions: ""))
        _ = try await collect(features.rewrite("thx", instruction: "Shorter", context: nil))
        #expect(provider.requests.first?.trusted.map(\.kind) == [.userInstruction])
        #expect(AISettings().userPreferencesText == nil)
        #expect(AISettings(writingInstructions: "Brief.").userPreferencesText == "How I write: Brief.")
    }

    @Test func aSummaryNeverCarriesThePreferences() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("A summary.") }
        let features = makeFeatures([provider], settings: AISettings(aboutMe: "About me text", writingInstructions: "Style"))
        let thread = AIThreadInput(threadKey: "t1", subject: "Plans",
                                   messages: [AIMessageInput(messageKey: "m1", from: "Sam <sam@example.com>", date: fixedNow,
                                                             bodyText: "Can we meet Friday?")])
        _ = try await collect(features.summarize(thread))
        for request in provider.requests {
            #expect(!request.trusted.contains { $0.kind == .userPreferences }, "\(request.task)")
            #expect(!request.renderedInput().contains("About me text"))
        }
    }

    @Test func styleExamplesStayInsideEmailDataOnThisMacOnly() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 8_192)) { _, _ in .text("Done.") }
        let features = makeFeatures([provider])
        let context = AIThreadInput(threadKey: "draft.1", subject: "", messages: [], accountKey: "home",
                                    styleExamples: examples)
        _ = try await collect(features.rewrite("thx", instruction: "Rewrite it in my own voice", context: context))
        let request = try #require(provider.requests.first)
        let styles = request.untrusted.filter { $0.kind == .styleExample }
        #expect(styles.map(\.id) == ["style-1", "style-2", "style-3"], "at most 3, blank ones dropped")
        #expect(styles.map(\.text) == [examples[0], examples[1], examples[3]])
        let blocks = try #require(RequestInspector.blocks(in: request.renderedInput(), nonce: request.nonce))
        #expect(blocks.filter { $0.kind == "styleExample" }.count == 3, "every example is inside a nonce-tagged block")
        #expect(RequestInspector.leaks(in: request).isEmpty)
        #expect(!request.renderedInput().contains(examples[4]))
        let long = DefaultAIFeatures.styleParts([String(repeating: "a", count: 2_000)], dataLocation: .onDevice)
        #expect(long.first?.text.count == DefaultAIFeatures.styleExampleCharacters)
    }

    @Test func aProviderOffThisMacNeverGetsTheExamples() async throws {
        let claude = ScriptedProvider(id: .agentClaude, capabilities: remoteCapabilities()) { _, _ in .text("Done.") }
        let features = makeFeatures([claude], settings: consenting([.agentClaude], AISettings(providerOrder: [.agentClaude])))
        let context = AIThreadInput(threadKey: "draft.1", subject: "", messages: [], accountKey: "home",
                                    styleExamples: examples)
        _ = try await collect(features.rewrite("thx", instruction: "Rewrite it in my own voice", context: context))
        let request = try #require(claude.requests.first)
        #expect(!request.untrusted.contains { $0.kind == .styleExample })
        #expect(!request.renderedInput().contains(examples[0]))
        #expect(DefaultAIFeatures.styleParts(examples, dataLocation: .appleCloud).isEmpty)
    }

    @Test func thePersonalTextIsCappedAndOlderSettingsDecodeWithoutIt() throws {
        let long = String(repeating: "x", count: 1_500)
        var settings = AISettings(aboutMe: long, writingInstructions: long)
        #expect(settings.aboutMe.count == AISettings.personalTextCap && settings.writingInstructions.count == 1_000)
        settings.aboutMe = long
        #expect(settings.aboutMe.count == AISettings.personalTextCap, "capped when set later too")
        let stored = Data(#"{"aboutMe":"\#(long)","writingInstructions":"Brief."}"#.utf8)
        let decoded = try JSONDecoder().decode(AISettings.self, from: stored)
        #expect(decoded.aboutMe.count == 1_000 && decoded.writingInstructions == "Brief.")
        let older = try JSONDecoder().decode(AISettings.self, from: Data(#"{"pccEnabled":true}"#.utf8))
        #expect(older.aboutMe.isEmpty && older.writingInstructions.isEmpty && older.pccEnabled)
        let round = AISettings(aboutMe: "Me.", writingInstructions: "Brief.")
        #expect(try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(round)) == round)
    }
}
