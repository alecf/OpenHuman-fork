import MailTheme
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct MotionTests {
    @Test func reduceMotionReachesTheResolvedTheme() {
        let store = ThemeStore()
        #expect(!store.resolved.tokens.reduceMotion)
        store.reduceMotion = true
        #expect(store.resolved.tokens.reduceMotion)
        #expect(store.resolve(store.preferences, appearance: .dark).tokens.reduceMotion, "previews follow it too")
        store.reduceMotion = false
        #expect(!store.resolved.tokens.reduceMotion)
    }

    @Test func animationsFollowThePolicy() {
        #expect(MotionSpec.instant.animation == nil)
        var tokens = ThemeTokens.light
        #expect(tokens.motion(tokens.motionEnterBase).animation != nil)
        tokens.reduceMotion = true
        let reduced = tokens.motion(tokens.motionEnterBase)
        #expect(reduced.animation != nil && !reduced.allowsTransform, "a short fade, no move")
    }
}
