import Foundation
import MailFeatures
import Testing
@testable import MailUI

@Test func heldToastCountdownRoundsUpAndEndsWithTheWindow() {
    let end = Date(timeIntervalSince1970: 1_000)
    #expect(ToastView.countdown(until: end, now: end.addingTimeInterval(-10)) == "10 s")
    #expect(ToastView.countdown(until: end, now: end.addingTimeInterval(-9.2)) == "10 s")
    #expect(ToastView.countdown(until: end, now: end.addingTimeInterval(-0.4)) == "1 s")
    #expect(ToastView.countdown(until: end, now: end) == nil)
    #expect(ToastView.countdown(until: end, now: end.addingTimeInterval(3)) == nil)
}
