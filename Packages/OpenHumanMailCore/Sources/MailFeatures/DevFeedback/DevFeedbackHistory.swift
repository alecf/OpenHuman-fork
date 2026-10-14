import Foundation
import Observation

@MainActor
@Observable
public final class DevFeedbackHistory {
    public static let capacity = 40
    public static let maxIDLength = 48

    public private(set) var commands: [DevFeedbackSnapshot.Command] = []
    @ObservationIgnored private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func record(_ id: String) {
        commands.append(DevFeedbackSnapshot.Command(at: now(), id: Self.sanitized(id)))
        if commands.count > Self.capacity { commands.removeFirst(commands.count - Self.capacity) }
    }

    static func sanitized(_ id: String) -> String {
        guard !id.isEmpty, id.count <= maxIDLength,
              id.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F })
        else { return "other" }
        return id
    }
}
