#if canImport(CloudKit)
import CloudKit
import Foundation
import OpenHumanCloudSync

public enum CloudKitMappingError: Error, Sendable, Hashable {
    case missingFields
    case payloadUnavailable
}

public enum CloudKitMapping {
    public static func zoneID(_ zone: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: CKCurrentUserDefaultName)
    }

    public static func zone(_ zoneID: CKRecordZone.ID) -> CloudZoneID {
        CloudZoneID(zoneID.zoneName)
    }

    public static func recordID(_ id: CloudRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(id.zone))
    }

    public static func id(_ recordID: CKRecord.ID) -> CloudRecordID {
        CloudRecordID(zone: zone(recordID.zoneID), name: recordID.recordName)
    }

    public static func pending(_ change: CloudPendingChange) -> CKSyncEngine.PendingRecordZoneChange {
        switch change {
        case .saveRecord(let id): return .saveRecord(recordID(id))
        case .deleteRecord(let id): return .deleteRecord(recordID(id))
        }
    }

    public static func pending(_ change: CKSyncEngine.PendingRecordZoneChange) -> CloudPendingChange? {
        switch change {
        case .saveRecord(let recordID): return .saveRecord(id(recordID))
        case .deleteRecord(let recordID): return .deleteRecord(id(recordID))
        @unknown default: return nil
        }
    }

    public static func pending(_ change: CloudPendingZoneChange) -> CKSyncEngine.PendingDatabaseChange {
        switch change {
        case .saveZone(let zone): return .saveZone(CKRecordZone(zoneID: zoneID(zone)))
        case .deleteZone(let zone): return .deleteZone(zoneID(zone))
        }
    }

    // Why: starting from the last server copy saves on top of its change tag
    public static func ckRecord(_ record: CloudRecord, assetFile: (Data) throws -> URL) throws -> CKRecord {
        let restored = record.systemFields.flatMap(restore).flatMap { $0.recordType == record.type ? $0 : nil }
        let ck = restored ?? CKRecord(recordType: record.type, recordID: recordID(record.id))
        ck.setObject(NSNumber(value: record.format), forKey: CloudRecordField.format)
        ck.setObject(record.keyID as NSString, forKey: CloudRecordField.keyID)
        ck.setObject(record.hlc.description as NSString, forKey: CloudRecordField.hlc)
        ck.setObject(record.device as NSString, forKey: CloudRecordField.device)
        ck.setObject(NSNumber(value: record.deleted), forKey: CloudRecordField.deleted)
        switch record.payload {
        case .inline(let data):
            ck.encryptedValues.setObject(data as NSData, forKey: CloudRecordField.blob)
            ck.setObject(nil, forKey: CloudRecordField.asset)
        case .asset(let data):
            ck.setObject(CKAsset(fileURL: try assetFile(data)), forKey: CloudRecordField.asset)
            ck.encryptedValues.setObject(nil, forKey: CloudRecordField.blob)
        case .unavailable:
            throw CloudKitMappingError.payloadUnavailable
        }
        return ck
    }

    public static func record(_ ck: CKRecord) throws -> CloudRecord {
        guard let format = (ck.object(forKey: CloudRecordField.format) as? NSNumber)?.intValue,
              let keyID = ck.object(forKey: CloudRecordField.keyID) as? String,
              let hlc = (ck.object(forKey: CloudRecordField.hlc) as? String).flatMap(HLC.init),
              let device = ck.object(forKey: CloudRecordField.device) as? String,
              let deleted = (ck.object(forKey: CloudRecordField.deleted) as? NSNumber)?.boolValue else {
            throw CloudKitMappingError.missingFields
        }
        let payload: CloudPayload
        if let blob = ck.encryptedValues.object(forKey: CloudRecordField.blob) as? Data {
            payload = .inline(blob)
        } else if let asset = ck.object(forKey: CloudRecordField.asset) as? CKAsset {
            payload = asset.fileURL.flatMap { try? Data(contentsOf: $0) }.map { CloudPayload.asset($0) } ?? .unavailable
        } else {
            throw CloudKitMappingError.missingFields
        }
        return CloudRecord(id: id(ck.recordID), type: ck.recordType, format: format, keyID: keyID, hlc: hlc, device: device,
                           deleted: deleted, payload: payload, systemFields: systemFields(ck))
    }

    public static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    public static func restore(_ systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    public static func error(_ error: any Error) -> CloudError {
        if let error = error as? CloudError { return error }
        guard let ck = error as? CKError else { return CloudError.from(error) }
        switch ck.code {
        case .serverRecordChanged: return .serverRecordChanged(ck.serverRecord.flatMap { try? record($0) })
        case .zoneNotFound: return .zoneNotFound
        case .userDeletedZone: return .userDeletedZone
        case .unknownItem: return .unknownItem
        case .limitExceeded: return .limitExceeded
        case .batchRequestFailed: return .batchRequestFailed
        case .partialFailure: return .partialFailure
        case .quotaExceeded: return .quotaExceeded
        case .notAuthenticated: return .notAuthenticated
        case .accountTemporarilyUnavailable: return .accountTemporarilyUnavailable
        case .networkUnavailable: return .networkUnavailable
        case .networkFailure, .serverResponseLost: return .networkFailure
        case .serviceUnavailable: return .serviceUnavailable
        case .requestRateLimited: return .requestRateLimited
        case .zoneBusy: return .zoneBusy
        case .changeTokenExpired: return .changeTokenExpired
        case .permissionFailure: return .permissionFailure
        case .missingEntitlement: return .missingEntitlement
        case .badContainer, .badDatabase: return .badContainer
        case .invalidArguments: return .invalidArguments
        case .incompatibleVersion: return .incompatibleVersion
        case .serverRejectedRequest: return .serverRejectedRequest
        case .assetFileNotFound, .assetFileModified, .assetNotAvailable: return .assetNotAvailable
        case .operationCancelled: return .operationCancelled
        case .managedAccountRestricted: return .managedAccountRestricted
        case .internalError: return .internalError
        default: return .other(ck.code.rawValue)
        }
    }

    public static func status(_ status: CKAccountStatus) -> CloudAccountStatus {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .couldNotDetermine
        @unknown default: return .couldNotDetermine
        }
    }

    public static func change(_ change: CKSyncEngine.Event.AccountChange.ChangeType) -> CloudAccountChange? {
        switch change {
        case .signIn: return .signIn
        case .signOut: return .signOut
        case .switchAccounts: return .switchAccounts
        @unknown default: return nil
        }
    }

    public static func reason(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> CloudZoneDeletionReason {
        switch reason {
        case .deleted: return .deleted
        case .purged: return .purged
        case .encryptedDataReset: return .encryptedDataReset
        @unknown default: return .deleted
        }
    }
}
#endif
