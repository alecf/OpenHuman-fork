import CoreGraphics
import MailFeatures
import MailTheme
import Testing
@testable import MailUI

struct ComposerPolishTests {
    @Test func theDraftLineReadsDraftToTheRecipients() {
        let plain = DraftLine.parts(isAuto: false, names: "Dana Ruiz")
        #expect(plain.lead == "Draft" && plain.rest == "to Dana Ruiz")
        let auto = DraftLine.parts(isAuto: true, names: "Dana Ruiz, Sam Lee")
        #expect(auto.lead == "Auto Draft" && auto.rest == "to Dana Ruiz, Sam Lee")
        let alone = DraftLine.parts(isAuto: false, names: nil)
        #expect(alone.lead == "Draft" && alone.rest == nil, "just \"Draft\" until there is a recipient")
        #expect(DraftLine.parts(isAuto: true, names: nil).lead == "Auto Draft")

        #expect(DraftLine.spoken(isAuto: false, names: "Dana Ruiz") == "Draft to Dana Ruiz")
        #expect(DraftLine.spoken(isAuto: true, names: "Dana Ruiz") == "Auto Draft to Dana Ruiz")
        #expect(DraftLine.spoken(isAuto: false, names: nil) == "Draft")
        #expect(DraftLine.spoken(isAuto: true, names: nil) == "Auto Draft")
    }

    @Test func theExamplesCardIsHalfTheBoxClamped() {
        #expect(AIComposerMetrics.examplesWidth(boxWidth: 480) == 280, "never narrower than 280")
        #expect(AIComposerMetrics.examplesWidth(boxWidth: 640) == 320)
        #expect(AIComposerMetrics.examplesWidth(boxWidth: 900) == 360, "never wider than 360")
        #expect(AIComposerMetrics.examplesWidth(boxWidth: 0) == 280, "before the box is measured")
    }

    @Test func thePromptRowIsTallerThanTheActionsRow() {
        #expect(AIComposerMetrics.promptHeight == 38)
        #expect(AIComposerMetrics.fieldHeight == 32)
        #expect(AIComposerMetrics.sendTarget >= AIComposerMetrics.sendButton, "the hit area holds the drawn circle")
        #expect(AIComposerMetrics.sendTarget <= AIComposerMetrics.promptHeight, "and fits the prompt row")
    }

    @Test func theHintShowsOnlyOnHoverOrAPreview() {
        func reveals(row: Bool = false, selection: Int? = nil, hovered: Int? = nil, live: Bool = true,
                     phase: InstantReplyModel.Phase = .ready) -> Bool {
            InstantReplyStrip.revealsHint(rowHovered: row, selection: selection, hovered: hovered, isLive: live, phase: phase)
        }
        #expect(!reveals(), "at rest the chips stand alone")
        #expect(reveals(row: true), "the pointer over the row")
        #expect(reveals(hovered: 1), "the pointer over a chip")
        #expect(reveals(selection: 0), "a chip previewed (⇥) while the row is live")
        #expect(!reveals(selection: 0, live: false), "a remembered preview once the user typed")
        #expect(!reveals(row: true, phase: .waiting))
        #expect(!reveals(row: true, phase: .quiet("No quick replies for this one.", canRetry: false)))
        #expect(!reveals(row: true, phase: .hidden))
        #expect(!reveals(row: true, phase: .used(0)))
    }

    @Test func theHintFadesInAndGoesAtOnce() {
        let light = ThemeTokens.light
        let reveal = light.motion(light.motionReveal, transform: false)
        #expect(reveal.seconds == 0.08 && reveal.animates, "motion.reveal: 80 ms in the built-in theme")
        #expect(InstantReplyStrip.hintMotion(revealing: true, reduceMotion: false, reveal: reveal) == reveal)
        #expect(InstantReplyStrip.hintMotion(revealing: false, reduceMotion: false, reveal: reveal) == .instant,
                "out at once (hover icons)")
        #expect(InstantReplyStrip.hintMotion(revealing: true, reduceMotion: true, reveal: reveal) == .instant,
                "Reduce Motion: at once both ways")
    }

    @Test func aKeycapShowsOnlyOnTheHoveredOrSelectedRow() {
        #expect(!QuickRepliesList.showsKeycap(isHovered: false, isSelected: false))
        #expect(QuickRepliesList.showsKeycap(isHovered: true, isSelected: false))
        #expect(QuickRepliesList.showsKeycap(isHovered: false, isSelected: true))
        #expect(QuickRepliesList.showsKeycap(isHovered: true, isSelected: true))
    }
}
