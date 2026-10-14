import Foundation
import MailTheme

public struct ToastTiming: Sendable, Equatable {
    public var action: Duration
    public var info: Duration
    public var error: Duration
    public var brief: Duration
    public var resume: Duration

    public init(action: Duration, info: Duration, error: Duration, brief: Duration, resume: Duration) {
        self.action = action
        self.info = info
        self.error = error
        self.brief = brief
        self.resume = resume
    }

    public init(theme: ThemeTokens) {
        func ms(_ value: Double) -> Duration { .milliseconds(Int64(max(0, value).rounded())) }
        self.init(action: ms(theme.motionToastAction), info: ms(theme.motionToastInfo), error: ms(theme.motionToastError),
                  brief: ms(theme.motionToastBrief), resume: ms(theme.motionToastResume))
    }

    public static let standard = ToastTiming(action: .seconds(6), info: .seconds(4), error: .seconds(10), brief: .seconds(2),
                                             resume: .milliseconds(1500))

    public func themed(_ duration: Duration) -> Duration {
        switch duration {
        case Self.standard.action: action
        case Self.standard.info: info
        case Self.standard.error: error
        case Self.standard.brief: brief
        default: duration
        }
    }
}
