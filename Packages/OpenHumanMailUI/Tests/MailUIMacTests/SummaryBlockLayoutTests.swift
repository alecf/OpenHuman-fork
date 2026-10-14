import MailTheme
import Testing
@testable import MailUIMac

@Suite struct SummaryBlockLayoutTests {
    typealias L = SummaryBlockLayout

    @Test func stages() {
        #expect(L.stage(showsLine: false, generating: false, offersSummarize: false, oneLineShows: false) == .absent)
        #expect(L.stage(showsLine: false, generating: false, offersSummarize: true, oneLineShows: false) == .offer)
        #expect(L.stage(showsLine: false, generating: false, offersSummarize: false, oneLineShows: true) == .offer)
        #expect(L.stage(showsLine: true, generating: true, offersSummarize: false, oneLineShows: true) == .generating)
        #expect(L.stage(showsLine: true, generating: false, offersSummarize: false, oneLineShows: false) == .settled)
    }

    @Test func theTextHoldsFourLinesOnlyWhileWritten() {
        #expect(L.holdsReservedHeight(.generating))
        #expect(L.maximumTextLines(stage: .generating) == 4)
        for stage in [L.Stage.absent, .offer, .settled] {
            #expect(!L.holdsReservedHeight(stage))
            #expect(L.maximumTextLines(stage: stage) == 0)
        }
    }

    @Test func gapsUseTheDesignedTokens() {
        for theme in [ThemeTokens.light, .dark] {
            #expect(L.gaps(stage: .absent, theme: theme) == .init(afterSubject: 32, afterBlock: 0))
            for stage in [L.Stage.offer, .generating, .settled] {
                #expect(L.gaps(stage: stage, theme: theme) == .init(afterSubject: 8, afterBlock: 16))
            }
        }
    }

    @Test func onlySettlingAndStartingOverAreAnchored() {
        #expect(L.anchors(from: .generating, to: .settled))
        #expect(L.anchors(from: .settled, to: .generating))
        #expect(!L.anchors(from: .offer, to: .generating), "the block appearing pushes the cards once")
        #expect(!L.anchors(from: .absent, to: .generating))
        #expect(!L.anchors(from: .generating, to: .offer), "a run that failed quietly gives its room back")
        #expect(!L.anchors(from: .generating, to: .generating), "chunks: the text's height is fixed")
        #expect(!L.anchors(from: .settled, to: .absent))
    }

    @Test func shrinkingAtTheTopSetsTheSpaceAsideAboveTheSubject() {
        #expect(L.absorb(delta: -40, slack: 0, scrollOffset: 0, anchored: true) == .init(slack: 40, scroll: 0))
        #expect(L.absorb(delta: -40, slack: 10, scrollOffset: 0, anchored: true) == .init(slack: 50, scroll: 0))
    }

    @Test func shrinkingWhileScrolledScrollsBackFirst() {
        #expect(L.absorb(delta: -40, slack: 0, scrollOffset: 300, anchored: true) == .init(slack: 0, scroll: -40))
        #expect(L.absorb(delta: -40, slack: 0, scrollOffset: 15, anchored: true) == .init(slack: 25, scroll: -15))
    }

    @Test func growingTakesTheSlackBackThenScrolls() {
        #expect(L.absorb(delta: 30, slack: 40, scrollOffset: 0, anchored: true) == .init(slack: 10, scroll: 0))
        #expect(L.absorb(delta: 60, slack: 40, scrollOffset: 0, anchored: true) == .init(slack: 0, scroll: 20))
        #expect(L.absorb(delta: 60, slack: 0, scrollOffset: 100, anchored: true) == .init(slack: 0, scroll: 60))
    }

    @Test func notAnchoredOnlyTheSlackIsTakenBack() {
        #expect(L.absorb(delta: 60, slack: 40, scrollOffset: 0, anchored: false) == .init(slack: 0, scroll: 0))
        #expect(L.absorb(delta: -60, slack: 40, scrollOffset: 100, anchored: false) == .init(slack: 40, scroll: 0))
        #expect(L.absorb(delta: 0, slack: 40, scrollOffset: 100, anchored: true) == .init(slack: 40, scroll: 0))
    }
}
