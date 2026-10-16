import Foundation
import OpenHumanCloudSync

public enum InMemoryCloudLocalFailure: Error, Sendable, Hashable {
    case refused
}

public actor InMemoryCloudLocal: CloudSyncLocal {
    public private(set) var items: [CloudRecordID: [String: CloudValue]] = [:]
    public private(set) var applied: [CloudLocalChange] = []
    private var refusing = false

    public init() {}

    public func apply(_ change: CloudLocalChange) throws {
        if refusing { throw InMemoryCloudLocalFailure.refused }
        applied.append(change)
        items[change.id] = change.isDeleted ? nil : change.values
    }

    public func set(_ id: CloudRecordID, _ values: [String: CloudValue]?) {
        items[id] = values
    }

    public func values(_ id: CloudRecordID) -> [String: CloudValue]? {
        items[id]
    }

    public func setRefusing(_ refusing: Bool) {
        self.refusing = refusing
    }
}
