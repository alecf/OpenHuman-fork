import Foundation
import Observation

public enum DevFeedbackAvailability: String, Sendable, Hashable {
    case devTools, off

    public var isAvailable: Bool { self == .devTools }
}

@MainActor
@Observable
public final class DevFeedbackSettings {
    public static let enabledKey = "devFeedback.enabled"
    public static let taildropTargetKey = "feedback.taildropTarget"

    public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    public var taildropTarget: String {
        didSet { defaults.set(taildropTarget, forKey: Self.taildropTargetKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.taildropTarget = defaults.string(forKey: Self.taildropTargetKey) ?? ""
    }
}

public struct DevFeedbackPaths: Sendable, Hashable {
    public var support: URL
    public var feedbackDirectory: URL

    public init(support: URL, feedbackDirectory: URL? = nil) {
        self.support = support
        self.feedbackDirectory = feedbackDirectory ?? support.appendingPathComponent("feedback", isDirectory: true)
    }

    public var checklistOverride: URL { support.appendingPathComponent("dev-test-checklist.json") }
    public var answers: URL { support.appendingPathComponent("dev-checklist-answers.json") }

    public static func resolve(home: String?, feedbackDirectory: String?,
                               fileManager: FileManager = .default) -> DevFeedbackPaths {
        let support: URL
        if let home, !home.isEmpty {
            support = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            support = base.appendingPathComponent("OpenHuman", isDirectory: true).appendingPathComponent("Mail", isDirectory: true)
        }
        let feedback = feedbackDirectory.flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return DevFeedbackPaths(support: support, feedbackDirectory: feedback)
    }
}
