import Testing
@testable import MailTheme

@Suite struct MotionPolicyTests {
    private let everyMotion: (ThemeTokens) -> [ThemeMotion] = { t in
        [t.motionInstant, t.motionEnterFast, t.motionExitFast, t.motionEnterBase, t.motionExitBase, t.motionReveal,
         t.motionSlow, t.motionProgress]
    }

    @Test func theNewTokensHoldTheirValues() {
        let t = ThemeTokens.light
        #expect([t.motionToastError, t.motionToastBrief, t.motionToastResume, t.motionBannerIdle, t.motionLaunchQuiet,
                 t.motionReducedFade, t.motionFooterNotice, t.motionSequenceReveal]
                == [10_000, 2_000, 1_500, 300, 1_000, 80, 2_000, 500])
        #expect(t.component.overlay.enterScale == 0.98 && t.component.overlay.enterOffset == 4)
        #expect(t.component.popover.enterOffset == 4 && t.component.modal.enterScale == 0.97)
        #expect(t.component.toast.enterOffset == 8 && t.component.toast.exitOffset == 4 && t.component.toast.gap == 8)
        #expect(t.component.thread.pillEnterOffset == 6)
        #expect(t.component.skeleton.fill == t.bgSunken && t.component.skeleton.pillWidth == 96)
        #expect(!t.reduceMotion, "resolved tables start without Reduce Motion; the theme store sets it")
    }

    @Test func everyTokenAsThemedWithoutReduceMotion() {
        let t = ThemeTokens.light
        for token in everyMotion(t) {
            let spec = MotionPolicy.spec(token, reduceMotion: false, reducedFade: 80)
            #expect(spec.seconds == token.seconds && spec.easing == (token.durationMs > 0 ? token.easing : .none))
            #expect(spec.allowsTransform == (token.durationMs > 0) && !spec.loops)
        }
        #expect(MotionPolicy.spec(t.motionProgress, reduceMotion: false, reducedFade: 80, loop: true).loops)
        #expect(MotionPolicy.spec(t.motionInstant, reduceMotion: false, reducedFade: 80) == .instant)
    }

    @Test func reduceMotionKeepsOnlyShortFades() {
        var t = ThemeTokens.light
        t.reduceMotion = true
        for token in everyMotion(t) {
            let spec = t.motion(token, loop: token == t.motionProgress)
            #expect(!spec.allowsTransform && !spec.loops)
            #expect(spec.seconds <= t.motionReducedFade / 1000)
            #expect(token.durationMs > 0 || spec == .instant, "zero stays zero")
        }
        #expect(t.motion(t.motionEnterBase).seconds == 0.08)
        #expect(t.motion(t.motionReveal).seconds == 0.08, "a reveal at the cap stays at the cap")
    }

    @Test func theResolvedThemeCarriesTheFlag() {
        let on = ResolvedTheme.light.applyingReduceMotion(true)
        #expect(on.tokens.reduceMotion && on.themeID == ResolvedTheme.light.themeID)
        #expect(on.applyingReduceMotion(false) == ResolvedTheme.light)
        #expect(ResolvedTheme.light.applyingReduceMotion(false) == ResolvedTheme.light)
    }
}
