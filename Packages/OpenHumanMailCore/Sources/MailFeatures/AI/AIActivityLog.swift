import Foundation
import OpenHumanAI
import Synchronization

public final class AIActivityLog: AIActivitySink {
    public static let capacity = 100
    private let records = Mutex<[AIActivityRecord]>([])

    public init() {}

    public func record(_ record: AIActivityRecord) async {
        records.withLock { list in
            list.append(record)
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        }
    }

    public var entries: [AIActivityRecord] { records.withLock { $0.reversed() } }

    public func clear() { records.withLock { $0.removeAll() } }
}
