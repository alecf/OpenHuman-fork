import Foundation
import MailActions
import MailModel

public enum ShortcutHintPolicy {
    public static let sources: Set<ActionSource> = [.toolbar, .menu]
    public static let learnedAfterKeyboardUses = 3
    public static let mouseUsesPerHint = 5
    public static let duration: Duration = ToastTiming.standard.brief

    public struct Settings: Sendable, Hashable {
        public var hintOnClick: Bool
        public var reduceMotion: Bool
        public var sources: Set<ActionSource>

        public init(hintOnClick: Bool = true, reduceMotion: Bool = false, sources: Set<ActionSource> = ShortcutHintPolicy.sources) {
            self.hintOnClick = hintOnClick
            self.reduceMotion = reduceMotion
            self.sources = sources
        }
    }

    public struct Hint: Sendable, Hashable {
        public let action: ActionID
        public let title: String
        public let keycaps: [String]
        public let duration: Duration
        public let animates: Bool

        public var message: String { "\(title): \(keycaps.joined(separator: " "))" }
    }

    public enum Use: Sendable, Hashable { case keyboard, mouse }

    public static func use(of source: ActionSource, sources: Set<ActionSource> = ShortcutHintPolicy.sources) -> Use? {
        if source == .keyboard { return .keyboard }
        return sources.contains(source) ? .mouse : nil
    }

    public static func decision(_ descriptor: ActionDescriptor?, source: ActionSource, counts: ShortcutUseCount,
                                availability: ActionAvailability = .enabled, scope: ActionScope = .global,
                                title: String? = nil, settings: Settings) -> Hint? {
        guard settings.hintOnClick, let descriptor, availability == .enabled,
              use(of: source, sources: settings.sources) == .mouse,
              counts.keyboard < learnedAfterKeyboardUses,
              counts.mouse > 0, (counts.mouse - 1) % mouseUsesPerHint == 0,
              let binding = HintBar.binding(of: descriptor, in: scope) else { return nil }
        let named = title ?? descriptor.title
        let shown = named == descriptor.title ? (descriptor.shortTitle ?? named) : named
        return Hint(action: descriptor.id, title: HintBar.title(shown), keycaps: binding.keycaps, duration: duration,
                    animates: !settings.reduceMotion)
    }
}
