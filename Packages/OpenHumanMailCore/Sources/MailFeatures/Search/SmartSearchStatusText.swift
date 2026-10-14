import Foundation
import MailModel

public struct SmartSearchHeaderStatus: Sendable, Equatable {
    public let text: String
    public let help: String

    public init(text: String, help: String) {
        self.text = text
        self.help = help
    }
}

public enum SmartSearchStatusText {
    public static let relatedSpoken = "related match"
    public static let describeTip = "Try describing it in other words."

    public static func percent(_ fraction: Double) -> Int {
        min(99, max(0, Int((fraction * 100).rounded(.down))))
    }

    public static func header(_ status: SmartSearchStatus) -> SmartSearchHeaderStatus? {
        switch status.phase {
        case .off, .ready:
            return nil
        case .indexing:
            return SmartSearchHeaderStatus(text: "Smart search: \(percent(status.fraction))% of your mail",
                                           help: "Related results cover the mail indexed so far.")
        case .paused(let reason):
            return SmartSearchHeaderStatus(
                text: "Smart search paused",
                help: "Paused: \(Self.reason(reason)). Related results cover \(percent(status.fraction))% of your mail.")
        }
    }

    public static func statusBar(_ status: SmartSearchStatus) -> String? {
        guard case .indexing = status.phase else { return nil }
        return "Preparing smart search: \(percent(status.fraction))%"
    }

    public static func reason(_ reason: SmartSearchStatus.PauseReason) -> String {
        switch reason {
        case .lowPower: "Low Power Mode is on"
        case .hot: "the Mac is hot"
        case .lowDisk: "not enough free disk space"
        }
    }
}
