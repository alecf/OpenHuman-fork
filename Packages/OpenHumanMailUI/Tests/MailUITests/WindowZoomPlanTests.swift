#if os(macOS)
import CoreGraphics
import Testing
@testable import MailUI

@Suite struct WindowZoomPlanTests {
    private let visible = CGRect(x: 0, y: 40, width: 1600, height: 960)
    private let minSize = CGSize(width: 960, height: 600)

    @Test func aSmallerWindowFillsTheVisibleFrameAndRemembersItself() {
        let current = CGRect(x: 100, y: 120, width: 1000, height: 700)
        let result = WindowZoomPlan.toggle(current: current, saved: nil, visible: visible, minSize: minSize)
        #expect(result.frame == visible)
        #expect(result.remember == current)
    }

    @Test func aFilledWindowReturnsToTheRememberedFrame() {
        let saved = CGRect(x: 100, y: 120, width: 1000, height: 700)
        let result = WindowZoomPlan.toggle(current: visible, saved: saved, visible: visible, minSize: minSize)
        #expect(result.frame == saved)
        #expect(result.remember == nil)
    }

    @Test func withNothingRememberedItReturnsToTheDefaultSizeCentred() {
        let result = WindowZoomPlan.toggle(current: visible, saved: nil, visible: visible, minSize: minSize)
        #expect(result.frame.size == WindowZoomPlan.defaultSize)
        #expect(result.frame.midX == visible.midX)
        #expect(result.frame.midY == visible.midY)
    }

    @Test func theDefaultSizeIsReducedToFitASmallDisplay() {
        let small = CGRect(x: 0, y: 25, width: 1280, height: 775)
        let frame = WindowZoomPlan.restoreFrame(saved: nil, visible: small, minSize: minSize)
        #expect(frame.size == CGSize(width: 1280, height: 775))
        #expect(frame == small)
    }

    @Test func theSizeNeverGoesBelowTheMinimum() {
        let saved = CGRect(x: 10, y: 60, width: 300, height: 200)
        let frame = WindowZoomPlan.restoreFrame(saved: saved, visible: visible, minSize: minSize)
        #expect(frame.size == minSize)
    }

    @Test func aRememberedFrameOnAnotherDisplayIsCentredOnThisOne() {
        let elsewhere = CGRect(x: 3000, y: 0, width: 1000, height: 700)
        let frame = WindowZoomPlan.restoreFrame(saved: elsewhere, visible: visible, minSize: minSize)
        #expect(frame.size == elsewhere.size)
        #expect(frame.midX == visible.midX)
        #expect(visible.contains(frame))
    }

    @Test func aRememberedFrameHangingOffTheEdgeIsPulledInside() {
        let saved = CGRect(x: 1200, y: 40, width: 1000, height: 700)
        let frame = WindowZoomPlan.restoreFrame(saved: saved, visible: visible, minSize: minSize)
        #expect(frame.maxX == visible.maxX)
        #expect(visible.contains(frame))
    }

    @Test func aSecondDisplayWithADifferentVisibleFrameFillsThatOne() {
        let second = CGRect(x: 1600, y: 0, width: 2560, height: 1415)
        let current = CGRect(x: 1700, y: 100, width: 1360, height: 860)
        let result = WindowZoomPlan.toggle(current: current, saved: nil, visible: second, minSize: minSize)
        #expect(result.frame == second)
    }

    @Test func filledMeansWithinAFewPointsOnEveryEdge() {
        #expect(WindowZoomPlan.isFilled(frame: visible.insetBy(dx: 2, dy: 2), visible: visible))
        #expect(!WindowZoomPlan.isFilled(frame: visible.insetBy(dx: 20, dy: 0), visible: visible))
        #expect(!WindowZoomPlan.isFilled(frame: visible.insetBy(dx: 0, dy: 20), visible: visible))
        #expect(!WindowZoomPlan.isFilled(frame: visible, visible: .zero))
    }

    @Test func twoTogglesReturnToTheStartingFrame() {
        let start = CGRect(x: 240, y: 90, width: 1180, height: 760)
        let first = WindowZoomPlan.toggle(current: start, saved: nil, visible: visible, minSize: minSize)
        let second = WindowZoomPlan.toggle(current: first.frame, saved: first.remember, visible: visible, minSize: minSize)
        #expect(second.frame == start)
    }

    @Test func theDoubleClickPreferenceMapsToTheAction() {
        #expect(TitleBarDoubleClickAction(preference: nil) == .zoom)
        #expect(TitleBarDoubleClickAction(preference: "Zoom") == .zoom)
        #expect(TitleBarDoubleClickAction(preference: "Maximize") == .zoom)
        #expect(TitleBarDoubleClickAction(preference: "Minimize") == .minimize)
        #expect(TitleBarDoubleClickAction(preference: "None") == .none)
    }
}
#endif
