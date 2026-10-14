import Foundation
import MailTheme
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ToastTimingTests {
    @Test func theBuiltInThemeGivesTheStandardLifetimes() {
        #expect(ToastTiming(theme: .light) == .standard)
        #expect(ToastTiming.standard.action == NoticeCenter.toastDuration && ToastTiming.standard.info == NoticeCenter.infoDuration)
        #expect(ToastTiming.standard.error == .seconds(10) && ToastTiming.standard.brief == .seconds(2))
        #expect(ToastTiming.standard.resume == .milliseconds(1_500))
    }

    @Test func aThemedTimingChangesStandardLifetimesOnly() {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let center = NoticeCenter(now: { start }, autoExpire: false)
        center.timing = ToastTiming(action: .seconds(3), info: .seconds(5), error: .seconds(12), brief: .seconds(1),
                                    resume: .seconds(1))
        let undo = center.post("Marked done", actionTitle: "Undo")
        let info = center.post("Diagnostics saved", duration: NoticeCenter.infoDuration)
        #expect(center.toasts.first { $0.id == undo }?.expiresAt == start.addingTimeInterval(3))
        #expect(center.toasts.first { $0.id == info }?.expiresAt == start.addingTimeInterval(5))
        let window = center.post("Discarded draft", actionTitle: "Undo", duration: .seconds(8))
        #expect(center.toasts.first { $0.id == window }?.expiresAt == start.addingTimeInterval(8))
        #expect(center.timing.themed(.seconds(2)) == .seconds(1) && center.timing.themed(.seconds(7)) == .seconds(7))
    }
}
