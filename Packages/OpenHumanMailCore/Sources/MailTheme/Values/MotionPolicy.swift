import Foundation

public struct MotionSpec: Hashable, Sendable {
    public var seconds: Double
    public var easing: Easing
    public var allowsTransform: Bool
    public var loops: Bool

    public init(seconds: Double, easing: Easing, allowsTransform: Bool, loops: Bool) {
        self.seconds = seconds
        self.easing = easing
        self.allowsTransform = allowsTransform
        self.loops = loops
    }

    public static let instant = MotionSpec(seconds: 0, easing: .none, allowsTransform: false, loops: false)

    public var animates: Bool { seconds > 0 }
}

public enum MotionPolicy {
    public static func spec(_ token: ThemeMotion, reduceMotion: Bool, reducedFade: Double, transform: Bool = true,
                            loop: Bool = false) -> MotionSpec {
        guard token.durationMs > 0 else { return .instant }
        guard reduceMotion else {
            return MotionSpec(seconds: token.seconds, easing: token.easing, allowsTransform: transform, loops: loop)
        }
        return MotionSpec(seconds: min(token.seconds, max(0, reducedFade) / 1000), easing: token.easing,
                          allowsTransform: false, loops: false)
    }
}

extension ThemeTokens {
    public func motion(_ token: ThemeMotion, transform: Bool = true, loop: Bool = false) -> MotionSpec {
        MotionPolicy.spec(token, reduceMotion: reduceMotion, reducedFade: motionReducedFade, transform: transform, loop: loop)
    }
}

extension ResolvedTheme {
    public func applyingReduceMotion(_ on: Bool) -> ResolvedTheme {
        guard tokens.reduceMotion != on else { return self }
        var tokens = self.tokens
        tokens.reduceMotion = on
        return ResolvedTheme(themeID: themeID, themeName: themeName, accentID: accentID, appearance: appearance,
                             tokens: tokens, emailColors: emailColors, issues: issues)
    }
}
