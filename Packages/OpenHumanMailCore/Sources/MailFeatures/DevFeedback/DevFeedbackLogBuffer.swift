import Foundation
import OpenHumanCore
import Synchronization

public final class DevFeedbackLogBuffer: Sendable {
    public struct Line: Codable, Sendable, Hashable {
        public var at: Date
        public var category: String
        public var level: String
        public var message: String

        public init(at: Date, category: String, level: String, message: String) {
            self.at = at
            self.category = category
            self.level = level
            self.message = message
        }
    }

    public static let defaultCapacity = 2_000
    public static let defaultWindow: TimeInterval = 10 * 60
    public static let maxLineLength = 1_000

    public let capacity: Int
    public let window: TimeInterval
    private let storage = Mutex<[Line]>([])

    public init(capacity: Int = DevFeedbackLogBuffer.defaultCapacity, window: TimeInterval = DevFeedbackLogBuffer.defaultWindow) {
        self.capacity = max(1, capacity)
        self.window = window
    }

    public func append(_ line: Line) {
        var line = line
        if line.message.count > Self.maxLineLength { line.message = String(line.message.prefix(Self.maxLineLength)) + "…" }
        storage.withLock { lines in
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func append(_ record: Log.Record) {
        append(Line(at: record.date, category: record.category.rawValue, level: record.level, message: record.message))
    }

    public func lines(now: Date) -> [Line] {
        let cutoff = now.addingTimeInterval(-window)
        return storage.withLock { $0.filter { $0.at >= cutoff && $0.at <= now.addingTimeInterval(1) } }
    }

    public func diagnosticLines(now: Date, limit: Int = 200) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return lines(now: now).filter { $0.level != "debug" }.suffix(max(0, limit)).map { line in
            let c = calendar.dateComponents([.hour, .minute, .second], from: line.at)
            return String(format: "%02d:%02d:%02d %@ %@ %@", c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                          line.level, line.category, line.message)
        }
    }

    public var count: Int { storage.withLock { $0.count } }

    public var sink: @Sendable (Log.Record) -> Void {
        { [weak self] record in self?.append(record) }
    }
}
