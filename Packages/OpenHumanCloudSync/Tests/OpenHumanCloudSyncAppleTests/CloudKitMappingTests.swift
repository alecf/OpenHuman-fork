import CloudKit
import Foundation
import OpenHumanCloudSync
import Security
import Testing
@testable import OpenHumanCloudSyncApple

@Suite("CloudKit mapping")
struct CloudKitMappingTests {
    let record = CloudRecord(id: CloudRecordID(zone: .app, name: "s.theme"), type: "Setting", format: 1, keyID: "k1",
                             hlc: HLC(millis: 42, counter: 1, device: "d1"), device: "d1", deleted: false,
                             payload: .inline(Data([1, 2, 3])))

    private func noAsset(_ data: Data) throws -> URL {
        Issue.record("no asset expected")
        return URL(fileURLWithPath: "/dev/null")
    }

    @Test func anInlineRecordRoundTrips() throws {
        let ck = try CloudKitMapping.ckRecord(record, assetFile: noAsset)
        #expect(ck.recordID.recordName == "s.theme")
        #expect(ck.recordID.zoneID.zoneName == "app")
        #expect(ck.object(forKey: CloudRecordField.blob) == nil)
        #expect(ck.object(forKey: CloudRecordField.asset) == nil)
        var back = try CloudKitMapping.record(ck)
        #expect(back.systemFields != nil)
        back.systemFields = nil
        #expect(back == record)
    }

    @Test func anAssetRecordRoundTripsAndItsFileIsRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ohcloudkit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let assets = CloudKitAssetFolder(url: folder)
        var large = record
        large.payload = .asset(Data(repeating: 9, count: 4_096))
        let ck = try CloudKitMapping.ckRecord(large, assetFile: { try assets.write($0) })
        #expect(ck.encryptedValues.object(forKey: CloudRecordField.blob) == nil)
        var back = try CloudKitMapping.record(ck)
        back.systemFields = nil
        #expect(back == large)
        assets.remove(for: [ck])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func systemFieldsRestoreTheSameRecord() throws {
        let ck = try CloudKitMapping.ckRecord(record, assetFile: noAsset)
        let fields = CloudKitMapping.systemFields(ck)
        let restored = try #require(CloudKitMapping.restore(fields))
        #expect(restored.recordID == ck.recordID)
        #expect(restored.recordType == "Setting")
        var saved = record
        saved.systemFields = fields
        let again = try CloudKitMapping.ckRecord(saved, assetFile: noAsset)
        #expect(again.recordID == ck.recordID)
    }

    @Test func errorsMapToTypedOutcomes() {
        #expect(CloudKitMapping.error(CKError(.zoneNotFound)) == .zoneNotFound)
        #expect(CloudKitMapping.error(CKError(.userDeletedZone)) == .userDeletedZone)
        #expect(CloudKitMapping.error(CKError(.limitExceeded)) == .limitExceeded)
        #expect(CloudKitMapping.error(CKError(.quotaExceeded)) == .quotaExceeded)
        #expect(CloudKitMapping.error(CKError(.serverRecordChanged)) == .serverRecordChanged(nil))
        #expect(CloudKitMapping.error(CKError(.networkFailure)).isTransient)
        #expect(CloudKitMapping.error(CancellationError()) == .operationCancelled)
    }

    @Test func aConflictCarriesTheServerRecord() throws {
        let server = try CloudKitMapping.ckRecord(record, assetFile: noAsset)
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        guard case .serverRecordChanged(let mapped?) = CloudKitMapping.error(error) else {
            Issue.record("expected the server record")
            return
        }
        #expect(mapped.id == record.id)
        #expect(mapped.payload == record.payload)
    }

    @Test func accountStatusesMap() {
        #expect(CloudKitMapping.status(.available) == .available)
        #expect(CloudKitMapping.status(.noAccount) == .noAccount)
        #expect(CloudKitMapping.status(.restricted) == .restricted)
        #expect(CloudKitMapping.status(.temporarilyUnavailable) == .temporarilyUnavailable)
        #expect(CloudKitMapping.status(.couldNotDetermine) == .couldNotDetermine)
    }
}

@Suite("Keychain key store")
struct KeychainCloudKeyStoreTests {
    @Test func keysAreSynchronizableItemsInTheSharedGroup() throws {
        let backend = RecordingKeychain()
        let store = KeychainCloudKeyStore(service: KeychainCloudKeyStore.defaultService, accessGroup: "TEAMID.dev.openhuman.shared",
                                          backend: backend)
        let key = CloudKey(id: "0a1b", material: Data(repeating: 3, count: 32))
        try store.save(key)
        try store.save(CloudKey(id: "0a1b", material: Data(repeating: 4, count: 32)))
        #expect(try store.loadKeys() == [key])
        try store.deleteAll()
        #expect(try store.loadKeys().isEmpty)
        let queries = backend.queries
        #expect(!queries.isEmpty)
        for query in queries {
            #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(query[kSecAttrAccessGroup as String] as? String == "TEAMID.dev.openhuman.shared")
            #expect(query[kSecAttrService as String] as? String == KeychainCloudKeyStore.defaultService)
        }
    }

    @Test func aMissingEntitlementIsReportedAsUnavailable() {
        let backend = RecordingKeychain()
        backend.failAdds(with: errSecMissingEntitlement)
        let store = KeychainCloudKeyStore(service: KeychainCloudKeyStore.defaultService, accessGroup: nil, backend: backend)
        #expect(throws: CloudKeyStoreError.unavailable(status: errSecMissingEntitlement)) {
            try store.save(CloudKey(id: "0a1b", material: Data(repeating: 3, count: 32)))
        }
    }
}

final class RecordingKeychain: CloudKeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var recorded: [[String: Any]] = []
    private var addFailure: OSStatus?

    var queries: [[String: Any]] {
        lock.withLock { recorded }
    }

    func failAdds(with status: OSStatus) {
        lock.withLock { addFailure = status }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            recorded.append(attributes)
            if let addFailure { return addFailure }
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            if items[account] != nil { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        lock.withLock {
            recorded.append(query)
            if let account = query[kSecAttrAccount as String] as? String {
                guard let data = items[account] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as NSData)
            }
            guard !items.isEmpty else { return (errSecItemNotFound, nil) }
            let listed: [[String: Any]] = items.keys.sorted().map { [kSecAttrAccount as String: $0] }
            return (errSecSuccess, listed as NSArray)
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            recorded.append(query)
            guard let account = query[kSecAttrAccount as String] as? String, items[account] != nil else {
                return errSecItemNotFound
            }
            items[account] = nil
            return errSecSuccess
        }
    }
}
