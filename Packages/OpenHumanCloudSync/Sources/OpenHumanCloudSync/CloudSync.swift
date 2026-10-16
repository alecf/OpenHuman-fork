import Foundation
import OpenHumanCore

public enum CloudSyncStatus: Sendable, Hashable {
    case stopped
    case running
    case unavailable(CloudAccountStatus)
    case needsConsent(CloudAccountChange)
    case deletedElsewhere
    case deletedHere
}

public enum CloudSyncError: Error, Sendable, Hashable {
    case unknownType(String)
    case invalidTypeName
    case invalidRecordName
    case invalidDeviceID
    case typeMismatch
    case notRunning
    case zoneDeletionIncomplete
}

public actor CloudSync: CloudDatabaseDelegate {
    public struct Configuration: Sendable {
        public var deviceID: String?
        public var types: [CloudRecordType]
        public var limits: CloudLimits
        public var tombstoneRetention: TimeInterval
        public var diagnosticsLimit: Int

        public init(deviceID: String? = nil, types: [CloudRecordType], limits: CloudLimits = .standard,
                    tombstoneRetention: TimeInterval = 90 * 86_400, diagnosticsLimit: Int = 500) {
            self.deviceID = deviceID
            self.types = types
            self.limits = limits
            self.tombstoneRetention = tombstoneRetention
            self.diagnosticsLimit = diagnosticsLimit
        }
    }

    private enum Meta {
        static let device = "device"
        static let hlc = "hlc"
        static let halt = "halt"
    }

    private enum Halt: String {
        case signedOut, switchedAccounts, deletedElsewhere, deletedHere

        var status: CloudSyncStatus {
            switch self {
            case .signedOut: return .needsConsent(.signOut)
            case .switchedAccounts: return .needsConsent(.switchAccounts)
            case .deletedElsewhere: return .deletedElsewhere
            case .deletedHere: return .deletedHere
            }
        }
    }

    private enum IngestOutcome {
        case applied, unchanged, skipped, unavailable, failed
        case parked(ParkReason)
    }

    public nonisolated let deviceID: String
    private let sidecar: CloudSyncSidecar
    private var keyring: CloudKeyring
    private var hlc: HLCClock
    private let clock: any OHClock
    private let local: any CloudSyncLocal
    private let makeDatabase: CloudDatabaseFactory
    private let types: [String: CloudRecordType]
    private let codec: CloudRecordCodec
    private let configuration: Configuration
    private var database: (any CloudDatabase)?
    private var starting = false
    private var batchLimit: Int
    private var needsRefetch = false
    private var accountStatus: CloudAccountStatus?
    private var zonesAwaitingDeletion: Set<CloudZoneID> = []

    public init(store location: CloudSyncStoreLocation, configuration: Configuration, keys: any CloudKeyStore,
                local: any CloudSyncLocal, clock: any OHClock,
                makeKey: @escaping @Sendable () -> CloudKey = { CloudKey.generate() },
                database makeDatabase: @escaping CloudDatabaseFactory) throws {
        guard configuration.types.allSatisfy(\.isValidName) else { throw CloudSyncError.invalidTypeName }
        let sidecar = try CloudSyncSidecar(location: location)
        let device: String
        if let stored = try sidecar.meta(Meta.device) {
            device = stored
        } else {
            device = configuration.deviceID ?? UUID().uuidString.lowercased()
            guard Self.isValidDevice(device) else { throw CloudSyncError.invalidDeviceID }
            try sidecar.setMeta(Meta.device, device)
        }
        self.deviceID = device
        self.sidecar = sidecar
        self.keyring = CloudKeyring(store: keys, makeKey: makeKey)
        self.hlc = HLCClock(device: device, last: try sidecar.meta(Meta.hlc).flatMap(HLC.init))
        self.clock = clock
        self.local = local
        self.makeDatabase = makeDatabase
        self.types = Dictionary(configuration.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.codec = CloudRecordCodec(inlineLimit: configuration.limits.inlinePayloadBytes)
        self.configuration = configuration
        self.batchLimit = max(1, configuration.limits.maxRecordsPerBatch)
    }

    public var status: CloudSyncStatus {
        if let halt = currentHalt { return halt.status }
        if database != nil { return .running }
        if let accountStatus, accountStatus != .available { return .unavailable(accountStatus) }
        return .stopped
    }

    @discardableResult
    public func start() async -> CloudSyncStatus {
        guard database == nil, !starting, currentHalt == nil else { return status }
        starting = true
        defer { starting = false }
        let db = makeDatabase(try? sidecar.engineState(), self)
        let account: CloudAccountStatus
        do {
            account = try await db.accountStatus()
        } catch {
            account = .couldNotDetermine
            note(.accountStatus, code: CloudError.from(error).code)
        }
        accountStatus = account
        note(.accountStatus, code: account.rawValue)
        guard account == .available, currentHalt == nil else {
            await db.cancel()
            return status
        }
        database = db
        batchLimit = max(1, configuration.limits.maxRecordsPerBatch)
        await retryParked()
        purgeExpiredTombstones()
        await enqueueOutstanding(on: db)
        note(.started)
        return status
    }

    public func stop() async {
        guard let db = database else { return }
        database = nil
        await db.cancel()
        note(.stopped)
    }

    // Why: after an account change or a deletion, only an explicit choice uploads this device's state again
    @discardableResult
    public func resume() async -> CloudSyncStatus {
        let db = database
        database = nil
        if let db { await db.cancel() }
        do {
            try sidecar.transaction {
                try sidecar.setMeta(Meta.halt, nil)
                try sidecar.setEngineState(nil)
                try sidecar.clearSyncState(zone: nil)
                try sidecar.clearZones()
                for id in try sidecar.documentIDs() {
                    guard let version = try sidecar.document(id)?.document.version else { continue }
                    if try sidecar.zoneState(id.zone) == nil { try sidecar.setZoneState(id.zone, .pending) }
                    try sidecar.putOutbox(OutboxRow(id: id, hlc: version, operation: .save, state: .ready, forceAsset: false))
                }
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
            return status
        }
        accountStatus = nil
        zonesAwaitingDeletion = []
        needsRefetch = false
        note(.resumed)
        return await start()
    }

    public func sync() async {
        await fetch()
        await send()
    }

    public func fetch() async {
        guard let db = database else { return }
        await retryParked()
        guard isCurrent(db) else { return }
        do {
            try await db.fetchChanges()
        } catch {
            note(.fetchFailed, code: CloudError.from(error).code)
        }
    }

    public func send() async {
        for _ in 0..<3 {
            guard let db = database else { return }
            do {
                try await db.sendChanges()
            } catch {
                let failure = CloudError.from(error)
                note(.sendFailed, code: failure.code)
                guard failure == .limitExceeded, batchLimit > 1 else { return }
                batchLimit = max(1, batchLimit / 2)
                note(.batchSplit, count: batchLimit)
                continue
            }
            guard needsRefetch, isCurrent(db) else { return }
            needsRefetch = false
            do {
                try await db.fetchChanges()
            } catch {
                note(.fetchFailed, code: CloudError.from(error).code)
                return
            }
            await requeue(state: .waiting)
        }
    }

    public func keysChanged() async {
        await retryParked()
    }

    public func deleteCloudData(zones selected: [CloudZoneID]? = nil) async throws {
        guard let db = database else { throw CloudSyncError.notRunning }
        do {
            try await db.fetchChanges()
        } catch {
            note(.fetchFailed, code: CloudError.from(error).code)
        }
        guard isCurrent(db) else { throw CloudSyncError.notRunning }
        let known = try sidecar.zones()
        let targets = (selected ?? Array(known.keys)).sorted()
        if !targets.isEmpty {
            try sidecar.transaction {
                for zone in targets {
                    try sidecar.clearSyncState(zone: zone)
                    try sidecar.setZoneState(zone, .deletedHere)
                }
            }
            zonesAwaitingDeletion.formUnion(targets)
            await db.addZoneChanges(targets.map { CloudPendingZoneChange.deleteZone($0) })
            do {
                try await db.sendChanges()
            } catch {
                note(.sendFailed, code: CloudError.from(error).code)
            }
            guard zonesAwaitingDeletion.isDisjoint(with: targets) else { throw CloudSyncError.zoneDeletionIncomplete }
        }
        if selected == nil {
            do {
                try keyring.deleteAll()
                note(.keysDeleted)
            } catch {
                note(.keychainFailed, code: Self.code(error))
                throw error
            }
        }
        note(.cloudDataDeleted, count: targets.count)
    }

    // `values` is the item's full current state; nil means it was deleted. Unchanged values are ignored.
    public func recordLocalChange(_ id: CloudRecordID, type: String, values: [String: CloudValue]?) async throws {
        guard types[type] != nil else { throw CloudSyncError.unknownType(type) }
        guard id.isValid else { throw CloudSyncError.invalidRecordName }
        let existing = try sidecar.document(id)
        if let existing, existing.type != type { throw CloudSyncError.typeMismatch }
        var document = existing?.document ?? CloudDocument()
        if let values {
            let incoming = values.filter { $0.value != .null }
            let reviving = existing == nil || document.isDeleted
            let changed = incoming.keys.filter { reviving || document.fields[$0]?.value != incoming[$0] }
            let removed = document.fields.filter { incoming[$0.key] == nil && $0.value.value != .null }.map(\.key)
            guard !changed.isEmpty || !removed.isEmpty else { return }
            let stamp = hlc.tick(now: clock.now)
            for key in changed { document.fields[key] = CloudField(value: incoming[key] ?? .null, hlc: stamp) }
            for key in removed { document.fields[key] = CloudField(value: .null, hlc: stamp) }
        } else {
            guard existing != nil, !document.isDeleted else { return }
            document.deletedAt = hlc.tick(now: clock.now)
        }
        guard let version = document.version else { return }
        let zoneState = try sidecar.zoneState(id.zone)
        let uploads = (zoneState?.syncs ?? true) && currentHalt == nil
        try sidecar.transaction {
            try sidecar.putDocument(id, type: type, document)
            try sidecar.setMeta(Meta.hlc, hlc.last?.description)
            if zoneState == nil { try sidecar.setZoneState(id.zone, .pending) }
            if uploads {
                let previous = try sidecar.outbox(id)
                try sidecar.putOutbox(OutboxRow(id: id, hlc: version, operation: .save,
                                                state: previous?.state == .waiting ? .waiting : .ready,
                                                forceAsset: previous?.forceAsset ?? false))
            }
        }
        guard uploads, let db = database else { return }
        if zoneState == nil { await db.addZoneChanges([.saveZone(id.zone)]) }
        await db.addRecordChanges([.saveRecord(id)])
    }

    public func document(_ id: CloudRecordID) -> CloudDocument? {
        (try? sidecar.document(id))?.document
    }

    public func zoneState(_ zone: CloudZoneID) -> CloudZoneState? {
        try? sidecar.zoneState(zone)
    }

    public func pendingUploadCount() -> Int {
        (try? sidecar.outboxCount()) ?? 0
    }

    public func waitingRecordCount() -> Int {
        (try? sidecar.parkedRows())?.count ?? 0
    }

    public func knownKeyIDs() -> [String] {
        keyring.keys.keys.sorted()
    }

    public func diagnostics(limit: Int = 200) -> [CloudDiagnostic] {
        (try? sidecar.log(limit: limit)) ?? []
    }

    public func nextBatch(for pending: [CloudPendingChange]) async -> CloudBatch? {
        guard database != nil, currentHalt == nil else { return nil }
        let zones = (try? sidecar.zones()) ?? [:]
        let limit = configuration.limits.maxBatchBytes
        var batch = CloudBatch()
        var bytes = 0
        let ordered = pending.sorted { ($0.id, $0.isSave ? 0 : 1) < ($1.id, $1.isSave ? 0 : 1) }
        building: for change in ordered {
            if batch.saves.count + batch.deletes.count >= batchLimit { break }
            guard let row = try? sidecar.outbox(change.id), row.state == .ready, row.pending == change,
                  zones[change.id.zone]?.syncs ?? true else {
                batch.discarded.append(change)
                continue
            }
            let started = !batch.saves.isEmpty || !batch.deletes.isEmpty
            if row.operation == .delete {
                if started, bytes + 512 > limit { break }
                batch.deletes.append(change.id)
                bytes += 512
                continue
            }
            guard let stored = try? sidecar.document(change.id) else {
                try? sidecar.deleteOutbox(change.id)
                batch.discarded.append(change)
                continue
            }
            let key: CloudKey
            do {
                let writing = try keyring.writingKey()
                if writing.created { note(.keyCreated) }
                key = writing.key
            } catch {
                note(.keychainFailed, code: Self.code(error))
                break building
            }
            let record: CloudRecord
            do {
                record = try codec.encode(stored.document, id: change.id, type: stored.type, key: key, writer: deviceID,
                                          systemFields: (try? sidecar.mirror(change.id))?.systemFields,
                                          forceAsset: row.forceAsset)
            } catch {
                note(.encodeFailed, code: Self.code(error))
                setOutboxState(change.id, .blocked)
                batch.discarded.append(change)
                continue
            }
            if started, bytes + record.estimatedBytes > limit { break }
            batch.saves.append(record)
            bytes += record.estimatedBytes
        }
        return batch.isEmpty ? nil : batch
    }

    public func handle(_ event: CloudEvent) async {
        if case .accountChange(let change) = event {
            await accountChanged(change)
            return
        }
        guard database != nil, currentHalt == nil else { return }
        switch event {
        case .stateUpdate(let data):
            try? sidecar.setEngineState(data)
        case .accountChange:
            break
        case .zonesDeleted(let deletions):
            await zonesDeleted(deletions)
        case .recordsFetched(let modified, let deleted, let unreadable):
            await recordsFetched(modified, deleted, unreadable: unreadable)
        case .zonesSent(let saved, let deleted, let failed):
            await zonesSent(saved: saved, deleted: deleted, failed: failed)
        case .recordsSent(let saved, let deleted, let failedSaves, let failedDeletes):
            await recordsSent(saved: saved, deleted: deleted, failedSaves: failedSaves, failedDeletes: failedDeletes)
        }
    }

    private func accountChanged(_ change: CloudAccountChange) async {
        note(.accountChanged, code: change.rawValue)
        guard change != .signIn else { return }
        let db = database
        database = nil
        needsRefetch = false
        zonesAwaitingDeletion = []
        // Why: nothing queued for the previous account may reach the new one
        do {
            try sidecar.transaction {
                try sidecar.clearSyncState(zone: nil)
                try sidecar.clearZones()
                try sidecar.setEngineState(nil)
                try sidecar.setMeta(Meta.halt, (change == .signOut ? Halt.signedOut : .switchedAccounts).rawValue)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
        // Why: cancelling from inside the engine's own callback could wait on itself
        if let db { Task { await db.cancel() } }
    }

    private func zonesDeleted(_ deletions: [CloudZoneDeletion]) async {
        for deletion in deletions.sorted(by: { $0.zone < $1.zone }) {
            note(.zoneDeleted, code: deletion.reason.rawValue + "." + deletion.zone.kind)
            switch deletion.reason {
            case .deleted, .purged: markZoneDeleted(deletion.zone, here: false)
            case .encryptedDataReset: await resetZone(deletion.zone)
            }
        }
        await haltIfNoZonesLeft()
    }

    private func zonesSent(saved: [CloudZoneID], deleted: [CloudZoneID], failed: [CloudZoneFailure]) async {
        for zone in saved where (try? sidecar.zoneState(zone)) == .pending {
            try? sidecar.setZoneState(zone, .active)
        }
        for zone in deleted { markZoneDeleted(zone, here: true) }
        for failure in failed {
            if failure.isDelete, failure.error == .zoneNotFound {
                markZoneDeleted(failure.zone, here: true)
                continue
            }
            note(failure.isDelete ? .zoneDeleteFailed : .zoneSaveFailed, code: failure.error.code)
        }
        await haltIfNoZonesLeft()
    }

    private func markZoneDeleted(_ zone: CloudZoneID, here: Bool) {
        let previous = try? sidecar.zoneState(zone)
        let state: CloudZoneState = here || previous == .deletedHere ? .deletedHere : .deletedRemotely
        zonesAwaitingDeletion.remove(zone)
        do {
            try sidecar.transaction {
                try sidecar.clearSyncState(zone: zone)
                try sidecar.setZoneState(zone, state)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
    }

    private func resetZone(_ zone: CloudZoneID) async {
        var changes: [CloudPendingChange] = []
        do {
            try sidecar.transaction {
                try sidecar.clearSyncState(zone: zone)
                try sidecar.setZoneState(zone, .pending)
                for id in try sidecar.documentIDs(in: zone) {
                    guard let version = try sidecar.document(id)?.document.version else { continue }
                    try sidecar.putOutbox(OutboxRow(id: id, hlc: version, operation: .save, state: .ready, forceAsset: false))
                    changes.append(.saveRecord(id))
                }
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
            return
        }
        note(.zoneReset, code: zone.kind, count: changes.count)
        guard let db = database else { return }
        await db.addZoneChanges([.saveZone(zone)])
        if !changes.isEmpty { await db.addRecordChanges(changes) }
    }

    private func haltIfNoZonesLeft() async {
        guard let zones = try? sidecar.zones(), !zones.isEmpty, zones.values.allSatisfy({ !$0.syncs }) else { return }
        let halt: Halt = zones.values.contains(.deletedRemotely) ? .deletedElsewhere : .deletedHere
        do {
            try sidecar.transaction {
                try sidecar.setMeta(Meta.halt, halt.rawValue)
                try sidecar.setEngineState(nil)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
        let db = database
        database = nil
        if let db { Task { await db.cancel() } }
    }

    private func recordsFetched(_ modified: [CloudRecord], _ deleted: [CloudRecordID], unreadable: Int) async {
        if unreadable > 0 { note(.unreadableRecords, count: unreadable) }
        var parked: [ParkReason: Int] = [:]
        for record in modified.sorted(by: { $0.id < $1.id }) {
            if case .parked(let reason) = await ingest(record) { parked[reason, default: 0] += 1 }
        }
        for id in deleted.sorted() { await hardDeleted(id) }
        if let count = parked[.key] { note(.waitingForKey, count: count) }
        if let count = parked[.format] { note(.unsupportedFormat, count: count) }
        if let count = parked[.type] { note(.unknownType, count: count) }
    }

    private func ingest(_ record: CloudRecord) async -> IngestOutcome {
        let id = record.id
        let zoneState = try? sidecar.zoneState(id.zone)
        if let zoneState, !zoneState.syncs { return .skipped }
        guard let type = types[record.type] else { return park(record, .type) }
        guard record.format <= CloudRecordCodec.currentFormat else { return park(record, .format) }
        let key: CloudKey?
        do {
            key = try keyring.key(id: record.keyID)
        } catch {
            note(.keychainFailed, code: Self.code(error))
            return park(record, .key)
        }
        guard let key else { return park(record, .key) }
        let remote: CloudDocument
        do {
            remote = try codec.decode(record, key: key)
        } catch CloudCodecError.payloadUnavailable {
            return .unavailable
        } catch {
            note(.decodeFailed, code: Self.code(error))
            return .failed
        }
        observe(record.hlc)
        let stored = try? sidecar.document(id)
        if let stored, stored.type != record.type {
            note(.decodeFailed, code: "typeMismatch")
            return .failed
        }
        let localDocument = stored?.document
        let merged = localDocument.map { type.merge($0, remote) } ?? remote
        let changedHere = Self.visible(merged) != Self.visible(localDocument)
        let pendingApply = (try? sidecar.parked(id))?.reason == .apply
        let uploads = merged != remote
        do {
            try sidecar.transaction {
                if zoneState == nil { try sidecar.setZoneState(id.zone, .active) }
                try sidecar.putMirror(id, MirrorRow(type: record.type, hlc: record.hlc, device: record.device,
                                                    deleted: record.deleted, keyID: record.keyID,
                                                    systemFields: record.systemFields,
                                                    digest: (try? CloudCanonical.digest(remote)) ?? Data()))
                try sidecar.deleteParked(id)
                if merged != localDocument { try sidecar.putDocument(id, type: record.type, merged) }
                let previous = try sidecar.outbox(id)
                if uploads, let version = merged.version {
                    try sidecar.putOutbox(OutboxRow(id: id, hlc: version, operation: .save, state: .ready,
                                                    forceAsset: previous?.forceAsset ?? false))
                } else if let previous, previous.operation == .save || !remote.isDeleted {
                    try sidecar.deleteOutbox(id)
                }
                try sidecar.setMeta(Meta.hlc, hlc.last?.description)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
            return .failed
        }
        if uploads { await database?.addRecordChanges([.saveRecord(id)]) }
        if changedHere || pendingApply { await applyLocally(id) }
        return changedHere ? .applied : .unchanged
    }

    private func park(_ record: CloudRecord, _ reason: ParkReason) -> IngestOutcome {
        do {
            try sidecar.putParked(ParkedRow(id: record.id, reason: reason, record: record))
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
        return .parked(reason)
    }

    private func observe(_ remote: HLC) {
        if remote.millis > HLCClock.millis(clock.now) + 3_600_000 { note(.clockSkew) }
        hlc.observe(remote)
    }

    // Why: re-applies if a local edit landed while the store was being written, so the store ends equal to the record
    private func applyLocally(_ id: CloudRecordID) async {
        for _ in 0..<3 {
            guard let stored = try? sidecar.document(id) else { return }
            let change = CloudLocalChange(id: id, type: stored.type, values: stored.document.values,
                                          isDeleted: stored.document.isDeleted)
            do {
                try await local.apply(change)
            } catch {
                note(.applyFailed)
                try? sidecar.putParked(ParkedRow(id: id, reason: .apply, record: nil))
                return
            }
            if (try? sidecar.document(id)) == stored { return }
        }
    }

    private func hardDeleted(_ id: CloudRecordID) async {
        if let row = try? sidecar.outbox(id), row.operation == .save {
            try? sidecar.deleteMirror(id)
            await database?.addRecordChanges([.saveRecord(id)])
            return
        }
        let stored = try? sidecar.document(id)
        do {
            try sidecar.transaction {
                try sidecar.deleteMirror(id)
                try sidecar.deleteOutbox(id)
                try sidecar.deleteParked(id)
                try sidecar.deleteDocument(id)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
            return
        }
        guard let stored, !stored.document.isDeleted else { return }
        do {
            try await local.apply(CloudLocalChange(id: id, type: stored.type, values: [:], isDeleted: true))
        } catch {
            note(.applyFailed)
        }
    }

    private func retryParked() async {
        _ = try? keyring.reload()
        guard let rows = try? sidecar.parkedRows(), !rows.isEmpty else { return }
        var resolved = 0
        for row in rows {
            switch row.reason {
            case .apply:
                try? sidecar.deleteParked(row.id)
                await applyLocally(row.id)
            case .key:
                guard let record = row.record, keyring.keys[record.keyID] != nil else { continue }
                switch await ingest(record) {
                case .applied, .unchanged: resolved += 1
                default: break
                }
            case .format, .type:
                guard let record = row.record, types[record.type] != nil,
                      record.format <= CloudRecordCodec.currentFormat else { continue }
                _ = await ingest(record)
            }
        }
        if resolved > 0 { note(.keyArrived, count: resolved) }
    }

    private func recordsSent(saved: [CloudRecord], deleted: [CloudRecordID], failedSaves: [CloudFailure],
                             failedDeletes: [CloudFailure]) async {
        var resend: [CloudPendingChange] = []
        var zoneSaves: [CloudZoneID] = []
        var limited: [CloudRecordID] = []
        var conflicts = 0
        var failures: [String: Int] = [:]
        for record in saved.sorted(by: { $0.id < $1.id }) {
            if confirmSaved(record) { resend.append(.saveRecord(record.id)) }
        }
        for id in deleted.sorted() {
            if forgetDeleted(id) { resend.append(.saveRecord(id)) }
        }
        for failure in failedSaves.sorted(by: { $0.id < $1.id }) {
            let id = failure.id
            switch failure.error {
            case .serverRecordChanged(let server):
                conflicts += 1
                await resolveConflict(id, server: server)
            case .zoneNotFound:
                let state = try? sidecar.zoneState(id.zone)
                if state == .active {
                    note(.zoneDeleted, code: "missing." + id.zone.kind)
                    markZoneDeleted(id.zone, here: false)
                } else if state == nil || state == .pending {
                    if !zoneSaves.contains(id.zone) { zoneSaves.append(id.zone) }
                    try? sidecar.setZoneState(id.zone, .pending)
                    resend.append(.saveRecord(id))
                }
            case .userDeletedZone:
                note(.zoneDeleted, code: CloudZoneDeletionReason.purged.rawValue + "." + id.zone.kind)
                markZoneDeleted(id.zone, here: false)
            case .unknownItem:
                try? sidecar.deleteMirror(id)
                resend.append(.saveRecord(id))
            case .limitExceeded:
                limited.append(id)
            case .batchRequestFailed:
                resend.append(.saveRecord(id))
            default:
                failures[failure.error.code, default: 0] += 1
            }
        }
        for failure in failedDeletes.sorted(by: { $0.id < $1.id }) {
            switch failure.error {
            case .unknownItem, .zoneNotFound:
                if forgetDeleted(failure.id) { resend.append(.saveRecord(failure.id)) }
            default:
                note(.recordDeleteFailed, code: failure.error.code)
            }
        }
        resend += splitAfterLimit(limited)
        if conflicts > 0 { note(.conflictMerged, count: conflicts) }
        for (code, count) in failures.sorted(by: { $0.key < $1.key }) {
            note(code == CloudError.quotaExceeded.code ? .quotaExceeded : .recordSaveFailed, code: code, count: count)
        }
        if let db = database {
            if !zoneSaves.isEmpty { await db.addZoneChanges(zoneSaves.map { CloudPendingZoneChange.saveZone($0) }) }
            if !resend.isEmpty { await db.addRecordChanges(resend) }
        }
        await haltIfNoZonesLeft()
    }

    private func confirmSaved(_ record: CloudRecord) -> Bool {
        let id = record.id
        let uploaded = try? openOwn(record)
        let current = try? sidecar.document(id)
        var resend = false
        do {
            try sidecar.transaction {
                try sidecar.putMirror(id, MirrorRow(type: record.type, hlc: record.hlc, device: record.device,
                                                    deleted: record.deleted, keyID: record.keyID,
                                                    systemFields: record.systemFields,
                                                    digest: uploaded.flatMap { try? CloudCanonical.digest($0) } ?? Data()))
                if try sidecar.zoneState(id.zone) == .pending { try sidecar.setZoneState(id.zone, .active) }
                guard let row = try sidecar.outbox(id), row.operation == .save, row.state == .ready else { return }
                let sentCurrent: Bool
                if let uploaded, let current {
                    sentCurrent = uploaded == current.document
                } else {
                    sentCurrent = row.hlc == record.hlc
                }
                if sentCurrent { try sidecar.deleteOutbox(id) } else { resend = true }
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
        return resend
    }

    private func forgetDeleted(_ id: CloudRecordID) -> Bool {
        if let row = try? sidecar.outbox(id), row.operation == .save {
            try? sidecar.deleteMirror(id)
            return row.state == .ready
        }
        do {
            try sidecar.transaction {
                try sidecar.deleteMirror(id)
                try sidecar.deleteOutbox(id)
                try sidecar.deleteParked(id)
                try sidecar.deleteDocument(id)
            }
        } catch {
            note(.storeFailed, code: Self.code(error))
        }
        return false
    }

    private func resolveConflict(_ id: CloudRecordID, server: CloudRecord?) async {
        guard let server, server.id == id else {
            waitForFetch(id)
            return
        }
        switch await ingest(server) {
        case .unavailable: waitForFetch(id)
        case .parked: setOutboxState(id, .waiting)
        case .applied, .unchanged, .skipped, .failed: break
        }
    }

    private func waitForFetch(_ id: CloudRecordID) {
        setOutboxState(id, .waiting)
        needsRefetch = true
        note(.conflictNeedsFetch)
    }

    // Why: the server can lower its limits at any time; halving converges on what it accepts
    private func splitAfterLimit(_ ids: [CloudRecordID]) -> [CloudPendingChange] {
        guard let first = ids.first else { return [] }
        if ids.count > 1 {
            batchLimit = max(1, ids.count / 2)
            note(.batchSplit, count: batchLimit)
            return ids.map { CloudPendingChange.saveRecord($0) }
        }
        guard var row = try? sidecar.outbox(first) else { return [] }
        if !row.forceAsset {
            row.forceAsset = true
            try? sidecar.putOutbox(row)
            note(.payloadMovedToAsset)
            return [.saveRecord(first)]
        }
        row.state = .blocked
        try? sidecar.putOutbox(row)
        note(.recordTooLarge)
        return []
    }

    private var currentHalt: Halt? {
        (try? sidecar.meta(Meta.halt)).flatMap(Halt.init(rawValue:))
    }

    private func isCurrent(_ db: any CloudDatabase) -> Bool {
        database.map { $0 === db } ?? false
    }

    private func enqueueOutstanding(on db: any CloudDatabase) async {
        let zones = (try? sidecar.zones()) ?? [:]
        let pendingZones = zones.filter { $0.value == .pending }.keys.sorted()
        if !pendingZones.isEmpty { await db.addZoneChanges(pendingZones.map { CloudPendingZoneChange.saveZone($0) }) }
        let rows = ((try? sidecar.outboxRows()) ?? []).filter { $0.state == .ready && (zones[$0.id.zone]?.syncs ?? true) }
        if !rows.isEmpty { await db.addRecordChanges(rows.map(\.pending)) }
    }

    private func requeue(state: OutboxState) async {
        let rows = ((try? sidecar.outboxRows()) ?? []).filter { $0.state == state }
        guard !rows.isEmpty else { return }
        for var row in rows {
            row.state = .ready
            try? sidecar.putOutbox(row)
        }
        await database?.addRecordChanges(rows.map(\.pending))
    }

    private func setOutboxState(_ id: CloudRecordID, _ state: OutboxState) {
        guard var row = try? sidecar.outbox(id) else { return }
        row.state = state
        try? sidecar.putOutbox(row)
    }

    private func purgeExpiredTombstones() {
        let cutoff = HLCClock.millis(clock.now.addingTimeInterval(-configuration.tombstoneRetention))
        guard let rows = try? sidecar.deletedMirrorRows() else { return }
        var count = 0
        for (id, mirror) in rows where mirror.hlc.millis < cutoff {
            guard (try? sidecar.outbox(id)) == nil, let stored = try? sidecar.document(id), stored.document.isDeleted else {
                continue
            }
            try? sidecar.putOutbox(OutboxRow(id: id, hlc: mirror.hlc, operation: .delete, state: .ready, forceAsset: false))
            count += 1
        }
        if count > 0 { note(.tombstonesPurged, count: count) }
    }

    private func openOwn(_ record: CloudRecord) throws -> CloudDocument {
        guard let key = try keyring.key(id: record.keyID) else { throw CloudCodecError.unknownKey(record.keyID) }
        return try codec.decode(record, key: key)
    }

    private static func visible(_ document: CloudDocument?) -> [String: CloudValue]? {
        guard let document, !document.isDeleted else { return nil }
        return document.values
    }

    private func note(_ kind: CloudDiagnostic.Kind, code: String? = nil, count: Int = 1) {
        try? sidecar.appendLog(CloudDiagnostic(date: clock.now, kind: kind, code: code, count: count),
                               keep: configuration.diagnosticsLimit)
    }

    private static func code(_ error: any Error) -> String {
        switch error {
        case let error as CloudKeyStoreError: return error.code
        case let error as CloudCodecError: return error.code
        case let error as CloudError: return error.code
        case is CloudSidecarError: return "sidecar"
        case is DecodingError, is EncodingError: return "coding"
        default: return "unknown"
        }
    }

    private static func isValidDevice(_ device: String) -> Bool {
        !device.isEmpty && device.utf8.count <= 64 && device.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}
