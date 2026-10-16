import Foundation

public enum CloudAccountStatus: String, Sendable, Hashable, CaseIterable {
    case available, noAccount, restricted, couldNotDetermine, temporarilyUnavailable
}

public enum CloudAccountChange: String, Sendable, Hashable, Codable {
    case signIn, signOut, switchAccounts
}

public enum CloudZoneDeletionReason: String, Sendable, Hashable, Codable {
    case deleted, purged, encryptedDataReset
}

public enum CloudPendingChange: Sendable, Hashable, Codable {
    case saveRecord(CloudRecordID)
    case deleteRecord(CloudRecordID)

    public var id: CloudRecordID {
        switch self {
        case .saveRecord(let id), .deleteRecord(let id): return id
        }
    }

    public var isSave: Bool {
        if case .saveRecord = self { return true }
        return false
    }
}

public enum CloudPendingZoneChange: Sendable, Hashable, Codable {
    case saveZone(CloudZoneID)
    case deleteZone(CloudZoneID)
}

public struct CloudBatch: Sendable, Hashable {
    public var saves: [CloudRecord]
    public var deletes: [CloudRecordID]
    public var discarded: [CloudPendingChange]

    public init(saves: [CloudRecord] = [], deletes: [CloudRecordID] = [], discarded: [CloudPendingChange] = []) {
        self.saves = saves
        self.deletes = deletes
        self.discarded = discarded
    }

    public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty && discarded.isEmpty }
}

public struct CloudFailure: Sendable, Hashable {
    public var id: CloudRecordID
    public var error: CloudError

    public init(id: CloudRecordID, error: CloudError) {
        self.id = id
        self.error = error
    }
}

public struct CloudZoneFailure: Sendable, Hashable {
    public var zone: CloudZoneID
    public var error: CloudError
    public var isDelete: Bool

    public init(zone: CloudZoneID, error: CloudError, isDelete: Bool) {
        self.zone = zone
        self.error = error
        self.isDelete = isDelete
    }
}

public struct CloudZoneDeletion: Sendable, Hashable {
    public var zone: CloudZoneID
    public var reason: CloudZoneDeletionReason

    public init(zone: CloudZoneID, reason: CloudZoneDeletionReason) {
        self.zone = zone
        self.reason = reason
    }
}

public enum CloudEvent: Sendable {
    case stateUpdate(Data)
    case accountChange(CloudAccountChange)
    case zonesDeleted([CloudZoneDeletion])
    case recordsFetched(modified: [CloudRecord], deleted: [CloudRecordID], unreadable: Int)
    case zonesSent(saved: [CloudZoneID], deleted: [CloudZoneID], failed: [CloudZoneFailure])
    case recordsSent(saved: [CloudRecord], deleted: [CloudRecordID], failedSaves: [CloudFailure], failedDeletes: [CloudFailure])
}

public enum CloudError: Error, Sendable, Hashable {
    case serverRecordChanged(CloudRecord?)
    case zoneNotFound
    case userDeletedZone
    case unknownItem
    case limitExceeded
    case batchRequestFailed
    case partialFailure
    case quotaExceeded
    case notAuthenticated
    case accountTemporarilyUnavailable
    case networkUnavailable
    case networkFailure
    case serviceUnavailable
    case requestRateLimited
    case zoneBusy
    case changeTokenExpired
    case permissionFailure
    case missingEntitlement
    case badContainer
    case invalidArguments
    case incompatibleVersion
    case serverRejectedRequest
    case assetNotAvailable
    case operationCancelled
    case managedAccountRestricted
    case internalError
    case other(Int)

    public static func from(_ error: any Error) -> CloudError {
        if let error = error as? CloudError { return error }
        if error is CancellationError { return .operationCancelled }
        return .other(0)
    }

    public var code: String {
        switch self {
        case .serverRecordChanged: return "serverRecordChanged"
        case .zoneNotFound: return "zoneNotFound"
        case .userDeletedZone: return "userDeletedZone"
        case .unknownItem: return "unknownItem"
        case .limitExceeded: return "limitExceeded"
        case .batchRequestFailed: return "batchRequestFailed"
        case .partialFailure: return "partialFailure"
        case .quotaExceeded: return "quotaExceeded"
        case .notAuthenticated: return "notAuthenticated"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .zoneBusy: return "zoneBusy"
        case .changeTokenExpired: return "changeTokenExpired"
        case .permissionFailure: return "permissionFailure"
        case .missingEntitlement: return "missingEntitlement"
        case .badContainer: return "badContainer"
        case .invalidArguments: return "invalidArguments"
        case .incompatibleVersion: return "incompatibleVersion"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetNotAvailable: return "assetNotAvailable"
        case .operationCancelled: return "operationCancelled"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .internalError: return "internalError"
        case .other(let code): return "other\(code)"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .notAuthenticated, .accountTemporarilyUnavailable, .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }
}

public protocol CloudDatabase: AnyObject, Sendable {
    func addZoneChanges(_ changes: [CloudPendingZoneChange]) async
    func addRecordChanges(_ changes: [CloudPendingChange]) async
    func fetchChanges() async throws
    func sendChanges() async throws
    func accountStatus() async throws -> CloudAccountStatus
    func cancel() async
}

public protocol CloudDatabaseDelegate: AnyObject, Sendable {
    func nextBatch(for pending: [CloudPendingChange]) async -> CloudBatch?
    func handle(_ event: CloudEvent) async
}

public typealias CloudDatabaseFactory = @Sendable (_ state: Data?, _ delegate: any CloudDatabaseDelegate) -> any CloudDatabase

public struct CloudLimits: Sendable, Hashable {
    public var maxRecordsPerBatch: Int
    public var maxBatchBytes: Int
    public var inlinePayloadBytes: Int

    // Why: 250 records per engine batch, 2 MB per request excluding assets, 1 MB per record; large payloads go to assets
    public init(maxRecordsPerBatch: Int = 250, maxBatchBytes: Int = 2_000_000, inlinePayloadBytes: Int = 50_000) {
        self.maxRecordsPerBatch = maxRecordsPerBatch
        self.maxBatchBytes = maxBatchBytes
        self.inlinePayloadBytes = inlinePayloadBytes
    }

    public static let standard = CloudLimits()
}

public struct CloudLocalChange: Sendable, Hashable {
    public let id: CloudRecordID
    public let type: String
    public let values: [String: CloudValue]
    public let isDeleted: Bool

    public init(id: CloudRecordID, type: String, values: [String: CloudValue], isDeleted: Bool) {
        self.id = id
        self.type = type
        self.values = values
        self.isDeleted = isDeleted
    }
}

public protocol CloudSyncLocal: Sendable {
    func apply(_ change: CloudLocalChange) async throws
}
