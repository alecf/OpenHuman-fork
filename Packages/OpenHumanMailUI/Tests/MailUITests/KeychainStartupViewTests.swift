#if os(macOS)
import AppKit
import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
private final class Presses {
    var count = 0
}

@MainActor
@Suite struct KeychainStartupViewTests {
    private static func sentences(_ text: String) -> [String] {
        text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test func theExplainerSaysWhatToChooseInPlainShortSentences() {
        let continued = Presses()
        let explainer = StartupProblem.keychainExplainer(continue: { continued.count += 1 })
        #expect(explainer.message == "macOS may ask for your login password a few times. Choose Always Allow so it does "
            + "not ask again.")
        #expect(explainer.action?.title == "Continue" && explainer.secondaryAction == nil)
        #expect(explainer.actionHint?.isEmpty == false && !explainer.offersQuit && explainer.details == nil)
        explainer.action?.run()
        #expect(continued.count == 1)
        for sentence in Self.sentences(explainer.message) {
            #expect(sentence.split(separator: " ").count <= 12, "\(sentence)")
        }
    }

    @Test func theRefusedScreenOffersTryAgainAndSignInAgainWithHints() {
        let tries = Presses()
        let signIns = Presses()
        let refused = StartupProblem.keychainRefused(tryAgain: { tries.count += 1 }, signInAgain: { signIns.count += 1 })
        #expect(refused.action?.title == "Try again" && refused.secondaryAction?.title == "Sign in again")
        #expect(refused.actionHint?.isEmpty == false && refused.secondaryHint == "Opens sign-in. Nothing is deleted.")
        #expect(!refused.offersQuit && refused.details == nil)
        refused.action?.run()
        refused.secondaryAction?.run()
        #expect(tries.count == 1 && signIns.count == 1)
        for sentence in Self.sentences(refused.title + ". " + refused.message) {
            #expect(sentence.split(separator: " ").count <= 12, "\(sentence)")
        }
    }

    @Test func bothScreensLayOutInBothThemes() {
        let screens = [StartupProblem.keychainExplainer(continue: {}),
                       StartupProblem.keychainRefused(tryAgain: {}, signInAgain: {})]
        for problem in screens {
            for theme in [ResolvedTheme.light, .dark] {
                let hosting = NSHostingView(rootView: StartupProblemView(problem: problem, quit: {}, copy: { _ in })
                    .environment(\.theme, theme))
                hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0, "\(problem.title)")
            }
        }
    }
}
#endif
