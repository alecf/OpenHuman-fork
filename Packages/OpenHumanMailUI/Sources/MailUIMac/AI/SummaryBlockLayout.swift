import Foundation
import MailTheme

enum SummaryBlockLayout {
    enum Stage: Equatable {
        case absent
        case offer
        case generating
        case settled
    }

    static let reservedLines = 4

    static func stage(showsLine: Bool, generating: Bool, offersSummarize: Bool, oneLineShows: Bool) -> Stage {
        if showsLine { return generating ? .generating : .settled }
        return offersSummarize || oneLineShows ? .offer : .absent
    }

    static func holdsReservedHeight(_ stage: Stage) -> Bool { stage == .generating }

    static func maximumTextLines(stage: Stage) -> Int {
        stage == .generating ? reservedLines : 0
    }

    static func gaps(stage: Stage, theme: ThemeTokens) -> Gaps {
        stage == .absent ? Gaps(afterSubject: theme.space8, afterBlock: 0)
            : Gaps(afterSubject: theme.space3, afterBlock: theme.space5)
    }

    struct Gaps: Equatable {
        var afterSubject: Double
        var afterBlock: Double
    }

    static func anchors(from old: Stage, to new: Stage) -> Bool {
        (old == .generating && new == .settled) || (old == .settled && new == .generating)
    }

    static func absorb(delta: Double, slack: Double, scrollOffset: Double, anchored: Bool) -> Absorbed {
        if delta > 0 {
            let fromSlack = min(slack, delta)
            return Absorbed(slack: slack - fromSlack, scroll: anchored ? delta - fromSlack : 0)
        }
        guard delta < 0, anchored else { return Absorbed(slack: slack, scroll: 0) }
        let fromScroll = min(max(0, scrollOffset), -delta)
        return Absorbed(slack: slack - delta - fromScroll, scroll: -fromScroll)
    }

    struct Absorbed: Equatable {
        var slack: Double
        var scroll: Double
    }
}
