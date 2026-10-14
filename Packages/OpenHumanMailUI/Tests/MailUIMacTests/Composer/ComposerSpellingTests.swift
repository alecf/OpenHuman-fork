import AppKit
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct ComposerSpellingTests {
    @Test func aNewEditorHasTheSystemFeaturesButNoWritingTools() {
        let text = ComposerTextView.make()
        #expect(text.writingToolsBehavior == .none, "D1: off until allowed")
        #expect(text.isContinuousSpellCheckingEnabled && text.isAutomaticSpellingCorrectionEnabled)
        #expect(!text.isGrammarCheckingEnabled && text.isAutomaticLinkDetectionEnabled)
        #expect(text.textFlags == ComposeTextFlags.standard)
    }

    @Test func configureSetsEveryFlag() {
        let text = ComposerTextView.make()
        let flags = ComposeTextFlags(continuousSpelling: false, autocorrect: false, grammar: true, textReplacement: false,
                                     quoteSubstitution: false, dashSubstitution: true, writingTools: true)
        text.configure(with: flags)
        #expect(!text.isContinuousSpellCheckingEnabled && !text.isAutomaticSpellingCorrectionEnabled)
        #expect(text.isGrammarCheckingEnabled && !text.isAutomaticTextReplacementEnabled)
        #expect(!text.isAutomaticQuoteSubstitutionEnabled && text.isAutomaticDashSubstitutionEnabled)
        #expect(text.isAutomaticLinkDetectionEnabled)
        #expect(text.writingToolsBehavior == .complete)
        var off = flags
        off.writingTools = false
        text.configure(with: off)
        #expect(text.writingToolsBehavior == .none && text.textFlags == off)
    }

    @Test func theEditorFollowsTheEnvironmentsSettingsForItsAccount() async {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNowForSpelling), featureFlags: FeatureFlags())
        #expect(env.compose.textSettings === env.composeText)
        let account = Account(id: AccountID(1), email: "robin@example.com", displayName: "Work", alias: nil, health: .active)
        env.composeText.allowWritingTools = true
        env.composeText.autocorrect = .off
        let text = ComposerTextView.make()
        text.configure(with: env.compose.textSettings.flags(for: account))
        #expect(text.writingToolsBehavior == .complete && !text.isAutomaticSpellingCorrectionEnabled)
    }

    @Test func correctionsTouchingProtectedTextAreDroppedAndMarksAreKept() {
        let body = "teh ;;teh {{frist_name}} write to teh@exmaple.com or https://exmaple.com/teh -- teh"
        let ns = body as NSString
        let plain = ns.range(of: "teh")
        let trigger = NSRange(location: ns.range(of: ";;teh").location + 2, length: 3)
        let variable = ns.range(of: "frist")
        let address = ns.range(of: "exmaple")
        let link = ns.range(of: "teh", options: [], range: NSRange(location: ns.range(of: "https").location,
                                                                     length: ns.length - ns.range(of: "https").location))
        let dash = ns.range(of: "--")
        let results: [NSTextCheckingResult] = [
            .correctionCheckingResult(range: plain, replacementString: "the"),
            .correctionCheckingResult(range: trigger, replacementString: "the"),
            .replacementCheckingResult(range: variable, replacementString: "first"),
            .correctionCheckingResult(range: address, replacementString: "example"),
            .correctionCheckingResult(range: link, replacementString: "the"),
            .dashCheckingResult(range: dash, replacementString: "–"),
            .spellCheckingResult(range: trigger),
        ]
        let kept = ComposerTextView.protecting(results, in: body)
        #expect(kept.map(\.range) == [plain, dash, trigger], "the plain word, the dash and the spelling mark stay")
    }

    @Test func everyComposerSharesOneSpellDocument() {
        let a = ComposerTextView.make()
        let b = ComposerTextView.make()
        #expect(a.spellCheckerDocumentTag == b.spellCheckerDocumentTag)
    }
}

private let fixedNowForSpelling = Date(timeIntervalSince1970: 1_791_000_000)
