#if canImport(CloudKit)
import CloudKit
import Foundation
import OpenHumanCloudSync
import Synchronization

public final class CloudKitDatabase: CloudDatabase {
    private let container: CKContainer
    private let engine: CKSyncEngine
    private let bridge: CloudKitEngineBridge

    public init(container: CKContainer, state: Data?, delegate: any CloudDatabaseDelegate, assetFolder: URL) {
        let bridge = CloudKitEngineBridge(delegate: delegate, assets: CloudKitAssetFolder(url: assetFolder))
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                       stateSerialization: serialization, delegate: bridge)
        self.container = container
        self.bridge = bridge
        engine = CKSyncEngine(configuration)
    }

    public static func factory(containerIdentifier: String, assetFolder: URL) -> CloudDatabaseFactory {
        { state, delegate in
            CloudKitDatabase(container: CKContainer(identifier: containerIdentifier), state: state, delegate: delegate,
                             assetFolder: assetFolder)
        }
    }

    public func addZoneChanges(_ changes: [CloudPendingZoneChange]) async {
        engine.state.add(pendingDatabaseChanges: changes.map { CloudKitMapping.pending($0) })
    }

    public func addRecordChanges(_ changes: [CloudPendingChange]) async {
        engine.state.add(pendingRecordZoneChanges: changes.map { CloudKitMapping.pending($0) })
    }

    public func fetchChanges() async throws {
        do {
            try await engine.fetchChanges()
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    public func sendChanges() async throws {
        do {
            try await engine.sendChanges()
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    public func accountStatus() async throws -> CloudAccountStatus {
        do {
            return CloudKitMapping.status(try await container.accountStatus())
        } catch {
            throw CloudKitMapping.error(error)
        }
    }

    public func cancel() async {
        await engine.cancelOperations()
    }
}

final class CloudKitEngineBridge: CKSyncEngineDelegate {
    private struct Target {
        weak var delegate: (any CloudDatabaseDelegate)?
    }

    private let target: Mutex<Target>
    private let assets: CloudKitAssetFolder

    init(delegate: any CloudDatabaseDelegate, assets: CloudKitAssetFolder) {
        target = Mutex(Target(delegate: delegate))
        self.assets = assets
        assets.removeAll()
    }

    private var delegate: (any CloudDatabaseDelegate)? {
        target.withLock { $0.delegate }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let delegate else { return }
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return }
            await delegate.handle(.stateUpdate(data))
        case .accountChange(let change):
            guard let mapped = CloudKitMapping.change(change.changeType) else { return }
            await delegate.handle(.accountChange(mapped))
        case .fetchedDatabaseChanges(let changes):
            let deletions = changes.deletions.map {
                CloudZoneDeletion(zone: CloudKitMapping.zone($0.zoneID), reason: CloudKitMapping.reason($0.reason))
            }
            if !deletions.isEmpty { await delegate.handle(.zonesDeleted(deletions)) }
        case .fetchedRecordZoneChanges(let changes):
            var modified: [CloudRecord] = []
            var unreadable = 0
            for modification in changes.modifications {
                if let record = try? CloudKitMapping.record(modification.record) {
                    modified.append(record)
                } else {
                    unreadable += 1
                }
            }
            let deleted = changes.deletions.map { CloudKitMapping.id($0.recordID) }
            await delegate.handle(.recordsFetched(modified: modified, deleted: deleted, unreadable: unreadable))
        case .sentDatabaseChanges(let sent):
            var failed = sent.failedZoneSaves.map {
                CloudZoneFailure(zone: CloudKitMapping.zone($0.zone.zoneID), error: CloudKitMapping.error($0.error), isDelete: false)
            }
            failed += sent.failedZoneDeletes.map {
                CloudZoneFailure(zone: CloudKitMapping.zone($0.key), error: CloudKitMapping.error($0.value), isDelete: true)
            }
            await delegate.handle(.zonesSent(saved: sent.savedZones.map { CloudKitMapping.zone($0.zoneID) },
                                             deleted: sent.deletedZoneIDs.map { CloudKitMapping.zone($0) }, failed: failed))
        case .sentRecordZoneChanges(let sent):
            let saved = sent.savedRecords.compactMap { try? CloudKitMapping.record($0) }
            let failedSaves = sent.failedRecordSaves.map {
                CloudFailure(id: CloudKitMapping.id($0.record.recordID), error: CloudKitMapping.error($0.error))
            }
            let failedDeletes = sent.failedRecordDeletes.map {
                CloudFailure(id: CloudKitMapping.id($0.key), error: CloudKitMapping.error($0.value))
            }
            assets.remove(for: sent.savedRecords + sent.failedRecordSaves.map(\.record))
            await delegate.handle(.recordsSent(saved: saved, deleted: sent.deletedRecordIDs.map { CloudKitMapping.id($0) },
                                               failedSaves: failedSaves, failedDeletes: failedDeletes))
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let mapped = pending.compactMap { CloudKitMapping.pending($0) }
        guard !mapped.isEmpty, let delegate, let batch = await delegate.nextBatch(for: mapped) else { return nil }
        if !batch.discarded.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.discarded.map { CloudKitMapping.pending($0) })
        }
        var records: [CKRecord] = []
        for record in batch.saves {
            if let ck = try? CloudKitMapping.ckRecord(record, assetFile: { try self.assets.write($0) }) { records.append(ck) }
        }
        let deletes = batch.deletes.map { CloudKitMapping.recordID($0) }
        guard !records.isEmpty || !deletes.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: deletes, atomicByZone: false)
    }
}

final class CloudKitAssetFolder: Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func write(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(UUID().uuidString).appendingPathExtension("asset")
        try data.write(to: file, options: .atomic)
        return file
    }

    func remove(for records: [CKRecord]) {
        let folder = url.standardizedFileURL.path
        for record in records {
            guard let asset = record.object(forKey: CloudRecordField.asset) as? CKAsset, let file = asset.fileURL,
                  file.standardizedFileURL.path.hasPrefix(folder) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
