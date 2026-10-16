import Foundation
import OpenHumanCloudSync
import Synchronization

public final class FakeCloudAccount: Sendable {
    public struct Limits: Sendable, Hashable {
        public var maxRecordsPerRequest: Int?
        public var maxBytesPerRequest: Int?

        public init(maxRecordsPerRequest: Int? = nil, maxBytesPerRequest: Int? = nil) {
            self.maxRecordsPerRequest = maxRecordsPerRequest
            self.maxBytesPerRequest = maxBytesPerRequest
        }
    }

    public struct Request: Sendable, Hashable {
        public enum Outcome: Sendable, Hashable { case accepted, limitExceeded }

        public let saves: Int
        public let deletes: Int
        public let bytes: Int
        public let outcome: Outcome

        public var count: Int { saves + deletes }
    }

    struct Modification: Sendable {
        var saved: [CloudRecord] = []
        var deleted: [CloudRecordID] = []
        var failedSaves: [CloudFailure] = []
        var failedDeletes: [CloudFailure] = []
    }

    struct ZoneModification: Sendable {
        var saved: [CloudZoneID] = []
        var deleted: [CloudZoneID] = []
    }

    struct DatabaseChanges: Sendable {
        var deleted: [CloudZoneDeletion]
        var changed: [CloudZoneID]
        var token: Int
    }

    struct ZoneChanges: Sendable {
        var modified: [CloudRecord]
        var deleted: [CloudRecordID]
        var token: Int
    }

    private struct Zone {
        var createdAt: Int
        var records: [String: CloudRecord] = [:]
        var tags: [String: Int] = [:]
    }

    private enum ChangeKind {
        case record(String)
        case zoneCreated
        case zoneDeleted(CloudZoneDeletionReason)
    }

    private struct Change {
        let sequence: Int
        let zone: CloudZoneID
        let kind: ChangeKind
    }

    private struct State {
        var zones: [CloudZoneID: Zone] = [:]
        var changes: [Change] = []
        var sequence = 0
        var nextTag = 0
        var limits = Limits()
        var quotaExceeded = false
        var requests: [Request] = []
    }

    private let state = Mutex(State())

    public init(limits: Limits = Limits()) {
        state.withLock { $0.limits = limits }
    }

    public var zoneIDs: [CloudZoneID] {
        state.withLock { $0.zones.keys.sorted() }
    }

    public func records(in zone: CloudZoneID) -> [CloudRecord] {
        state.withLock { state in
            let records = state.zones[zone].map { Array($0.records.values) } ?? []
            return records.sorted { $0.id < $1.id }
        }
    }

    public func record(_ id: CloudRecordID) -> CloudRecord? {
        state.withLock { $0.zones[id.zone]?.records[id.name] }
    }

    public var requests: [Request] {
        state.withLock { $0.requests }
    }

    public func setLimits(_ limits: Limits) {
        state.withLock { $0.limits = limits }
    }

    public func setQuotaExceeded(_ exceeded: Bool) {
        state.withLock { $0.quotaExceeded = exceeded }
    }

    public func purgeZone(_ zone: CloudZoneID) {
        state.withLock { state in
            guard state.zones.removeValue(forKey: zone) != nil else { return }
            Self.append(&state, zone, .zoneDeleted(.purged))
        }
    }

    func modifyZones(saving saves: [CloudZoneID], deleting deletes: [CloudZoneID]) -> ZoneModification {
        state.withLock { state in
            var result = ZoneModification()
            for zone in saves {
                if state.zones[zone] == nil {
                    state.sequence += 1
                    state.zones[zone] = Zone(createdAt: state.sequence)
                    state.changes.append(Change(sequence: state.sequence, zone: zone, kind: .zoneCreated))
                }
                result.saved.append(zone)
            }
            for zone in deletes {
                if state.zones.removeValue(forKey: zone) != nil { Self.append(&state, zone, .zoneDeleted(.deleted)) }
                result.deleted.append(zone)
            }
            return result
        }
    }

    func modify(saves: [CloudRecord], deletes: [CloudRecordID]) -> Modification {
        state.withLock { state in
            var result = Modification()
            let bytes = saves.reduce(0) { $0 + $1.estimatedBytes } + deletes.count * 512
            let count = saves.count + deletes.count
            let overCount = state.limits.maxRecordsPerRequest.map { count > $0 } ?? false
            let overBytes = state.limits.maxBytesPerRequest.map { bytes > $0 } ?? false
            if overCount || overBytes {
                state.requests.append(Request(saves: saves.count, deletes: deletes.count, bytes: bytes, outcome: .limitExceeded))
                result.failedSaves = saves.map { CloudFailure(id: $0.id, error: .limitExceeded) }
                result.failedDeletes = deletes.map { CloudFailure(id: $0, error: .limitExceeded) }
                return result
            }
            state.requests.append(Request(saves: saves.count, deletes: deletes.count, bytes: bytes, outcome: .accepted))
            for record in saves {
                switch Self.save(record, into: &state) {
                case .success(let stored): result.saved.append(stored)
                case .failure(let error): result.failedSaves.append(CloudFailure(id: record.id, error: error))
                }
            }
            for id in deletes {
                guard state.zones[id.zone] != nil else {
                    result.failedDeletes.append(CloudFailure(id: id, error: .zoneNotFound))
                    continue
                }
                if state.zones[id.zone]?.records.removeValue(forKey: id.name) != nil {
                    state.zones[id.zone]?.tags[id.name] = nil
                    Self.append(&state, id.zone, .record(id.name))
                }
                result.deleted.append(id)
            }
            return result
        }
    }

    func databaseChanges(since token: Int) -> DatabaseChanges {
        state.withLock { state in
            let recent = state.changes.filter { $0.sequence > token }
            var deleted: [CloudZoneDeletion] = []
            // A fetch from no token lists only zones that exist now
            for change in recent where token > 0 {
                if case .zoneDeleted(let reason) = change.kind { deleted.append(CloudZoneDeletion(zone: change.zone, reason: reason)) }
            }
            let changed = Set(recent.map(\.zone)).filter { state.zones[$0] != nil }.sorted()
            return DatabaseChanges(deleted: deleted, changed: changed, token: state.sequence)
        }
    }

    func zoneChanges(_ zone: CloudZoneID, since token: Int) -> ZoneChanges {
        state.withLock { state in
            guard let current = state.zones[zone] else { return ZoneChanges(modified: [], deleted: [], token: token) }
            let floor = max(token, current.createdAt)
            var names: [String] = []
            var latest = token
            for change in state.changes where change.zone == zone && change.sequence > floor {
                latest = max(latest, change.sequence)
                if case .record(let name) = change.kind, !names.contains(name) { names.append(name) }
            }
            var modified: [CloudRecord] = []
            var deleted: [CloudRecordID] = []
            for name in names.sorted() {
                if let record = current.records[name] { modified.append(record) } else {
                    deleted.append(CloudRecordID(zone: zone, name: name))
                }
            }
            return ZoneChanges(modified: modified, deleted: deleted, token: max(latest, floor))
        }
    }

    private static func save(_ record: CloudRecord, into state: inout State) -> Result<CloudRecord, CloudError> {
        guard var zone = state.zones[record.id.zone] else { return .failure(.zoneNotFound) }
        if state.quotaExceeded { return .failure(.quotaExceeded) }
        let sentTag = record.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let existing = zone.records[record.id.name] {
            guard let sentTag, sentTag == zone.tags[record.id.name] else {
                var server = existing
                if case .asset = server.payload { server.payload = .unavailable }
                return .failure(.serverRecordChanged(server))
            }
        } else if sentTag != nil {
            return .failure(.unknownItem)
        }
        state.nextTag += 1
        var stored = record
        stored.systemFields = Data(String(state.nextTag).utf8)
        zone.records[record.id.name] = stored
        zone.tags[record.id.name] = state.nextTag
        state.zones[record.id.zone] = zone
        append(&state, record.id.zone, .record(record.id.name))
        return .success(stored)
    }

    private static func append(_ state: inout State, _ zone: CloudZoneID, _ kind: ChangeKind) {
        state.sequence += 1
        state.changes.append(Change(sequence: state.sequence, zone: zone, kind: kind))
    }
}
