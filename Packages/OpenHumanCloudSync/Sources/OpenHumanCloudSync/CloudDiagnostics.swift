import Foundation

// Why: no personal data; entries hold only kinds, typed codes and counts
public struct CloudDiagnostic: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case started
        case stopped
        case accountStatus
        case accountChanged
        case fetchFailed
        case sendFailed
        case recordSaveFailed
        case recordDeleteFailed
        case zoneSaveFailed
        case zoneDeleteFailed
        case conflictMerged
        case conflictNeedsFetch
        case waitingForKey
        case keyArrived
        case keyCreated
        case keysDeleted
        case keychainFailed
        case unsupportedFormat
        case unknownType
        case unreadableRecords
        case decodeFailed
        case encodeFailed
        case batchSplit
        case payloadMovedToAsset
        case recordTooLarge
        case quotaExceeded
        case zoneDeleted
        case zoneReset
        case cloudDataDeleted
        case applyFailed
        case storeFailed
        case clockSkew
        case tombstonesPurged
        case resumed
    }

    public let date: Date
    public let kind: Kind
    public let code: String?
    public let count: Int

    init(date: Date, kind: Kind, code: String?, count: Int) {
        self.date = date
        self.kind = kind
        self.code = code
        self.count = count
    }
}
