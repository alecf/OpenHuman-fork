import Foundation
import SQLite3

public enum CloudSyncStoreLocation: Sendable, Hashable {
    case inMemory
    case file(URL)
}

public enum CloudZoneState: String, Sendable, Hashable, CaseIterable {
    case pending, active, deletedRemotely, deletedHere

    var syncs: Bool { self == .pending || self == .active }
}

public enum CloudSidecarError: Error, Sendable, Equatable {
    case open(Int32)
    case statement(Int32)
    case newerSchema(Int64)
}

enum SQLValue: Hashable {
    case int(Int64), real(Double), text(String), blob(Data), null

    var int: Int64? { if case .int(let value) = self { return value }; return nil }
    var real: Double? { if case .real(let value) = self { return value }; return nil }
    var text: String? { if case .text(let value) = self { return value }; return nil }
    var blob: Data? { if case .blob(let value) = self { return value }; return nil }

    init(_ text: String?) { self = text.map { .text($0) } ?? .null }
    init(_ data: Data?) { self = data.map { .blob($0) } ?? .null }
    init(_ flag: Bool) { self = .int(flag ? 1 : 0) }
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, handle != nil else {
            sqlite3_close_v2(handle)
            handle = nil
            throw CloudSidecarError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CloudSidecarError.statement(sqlite3_errcode(handle))
        }
    }

    func run(_ sql: String, _ arguments: [SQLValue] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw CloudSidecarError.statement(status) }
    }

    func rows(_ sql: String, _ arguments: [SQLValue] = []) throws -> [[SQLValue]] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var result: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CloudSidecarError.statement(status) }
            let columns = sqlite3_column_count(statement)
            result.append((0..<columns).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT: return .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
                default: return .null
                }
            })
        }
        return result
    }

    private func prepare(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw CloudSidecarError.statement(status)
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v) where v.isEmpty: sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum OutboxOperation: String { case save, delete }
enum OutboxState: String { case ready, waiting, blocked }
enum ParkReason: String { case key, format, type, apply }

struct OutboxRow: Hashable {
    var id: CloudRecordID
    var hlc: HLC
    var operation: OutboxOperation
    var state: OutboxState
    var forceAsset: Bool

    var pending: CloudPendingChange { operation == .save ? .saveRecord(id) : .deleteRecord(id) }
}

struct MirrorRow: Hashable {
    var type: String
    var hlc: HLC
    var device: String
    var deleted: Bool
    var keyID: String
    var systemFields: Data?
    var digest: Data
}

struct ParkedRow {
    var id: CloudRecordID
    var reason: ParkReason
    var record: CloudRecord?
}

struct StoredDocument: Hashable {
    var type: String
    var document: CloudDocument
}

final class CloudSyncSidecar {
    static let schemaVersion: Int64 = 1

    private let db: SQLiteConnection
    private var depth = 0

    init(location: CloudSyncStoreLocation) throws {
        switch location {
        case .inMemory:
            db = try SQLiteConnection(path: ":memory:")
        case .file(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try SQLiteConnection(path: url.path)
            try db.execute("PRAGMA journal_mode=WAL")
        }
        try migrate()
    }

    private func migrate() throws {
        let version = try db.rows("PRAGMA user_version").first?.first?.int ?? 0
        if version > Self.schemaVersion { throw CloudSidecarError.newerSchema(version) }
        guard version < 1 else { return }
        try transaction {
            try db.execute(Self.schemaV1)
            try db.execute("PRAGMA user_version = 1")
        }
    }

    private static let schemaV1 = """
        CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE zones(zone TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE records(zone TEXT NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL, document BLOB NOT NULL,
            PRIMARY KEY(zone, name)) WITHOUT ROWID;
        CREATE TABLE mirror(zone TEXT NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL, hlc TEXT NOT NULL,
            device TEXT NOT NULL, deleted INTEGER NOT NULL, key_id TEXT NOT NULL, system_fields BLOB, digest BLOB NOT NULL,
            PRIMARY KEY(zone, name)) WITHOUT ROWID;
        CREATE TABLE outbox(zone TEXT NOT NULL, name TEXT NOT NULL, hlc TEXT NOT NULL, operation TEXT NOT NULL,
            state TEXT NOT NULL, force_asset INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(zone, name)) WITHOUT ROWID;
        CREATE TABLE parked(zone TEXT NOT NULL, name TEXT NOT NULL, reason TEXT NOT NULL, record BLOB,
            PRIMARY KEY(zone, name)) WITHOUT ROWID;
        CREATE TABLE engine_state(id INTEGER PRIMARY KEY CHECK (id = 1), blob BLOB NOT NULL);
        CREATE TABLE log(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, kind TEXT NOT NULL, code TEXT,
            count INTEGER NOT NULL);
        """

    func transaction(_ body: () throws -> Void) throws {
        if depth > 0 {
            depth += 1
            defer { depth -= 1 }
            try body()
            return
        }
        try db.execute("BEGIN IMMEDIATE")
        depth = 1
        defer { depth = 0 }
        do {
            try body()
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    func meta(_ key: String) throws -> String? {
        try db.rows("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.first?.text
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        } else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func zoneState(_ zone: CloudZoneID) throws -> CloudZoneState? {
        try db.rows("SELECT state FROM zones WHERE zone = ?", [.text(zone.name)]).first?.first?.text
            .flatMap(CloudZoneState.init(rawValue:))
    }

    func setZoneState(_ zone: CloudZoneID, _ state: CloudZoneState) throws {
        try db.run("INSERT INTO zones(zone, state) VALUES(?, ?) ON CONFLICT(zone) DO UPDATE SET state = excluded.state",
                   [.text(zone.name), .text(state.rawValue)])
    }

    func zones() throws -> [CloudZoneID: CloudZoneState] {
        var result: [CloudZoneID: CloudZoneState] = [:]
        for row in try db.rows("SELECT zone, state FROM zones") {
            guard let name = row[0].text, let state = row[1].text.flatMap(CloudZoneState.init(rawValue:)) else { continue }
            result[CloudZoneID(name)] = state
        }
        return result
    }

    func clearZones() throws {
        try db.run("DELETE FROM zones")
    }

    func document(_ id: CloudRecordID) throws -> StoredDocument? {
        guard let row = try db.rows("SELECT type, document FROM records WHERE zone = ? AND name = ?", key(id)).first,
              let type = row[0].text, let data = row[1].blob else { return nil }
        return StoredDocument(type: type, document: try JSONDecoder().decode(CloudDocument.self, from: data))
    }

    func putDocument(_ id: CloudRecordID, type: String, _ document: CloudDocument) throws {
        let encoded = try CloudCanonical.encode(document)
        try db.run("""
            INSERT INTO records(zone, name, type, document) VALUES(?, ?, ?, ?)
            ON CONFLICT(zone, name) DO UPDATE SET type = excluded.type, document = excluded.document
            """, key(id) + [.text(type), .blob(encoded)])
    }

    func deleteDocument(_ id: CloudRecordID) throws {
        try db.run("DELETE FROM records WHERE zone = ? AND name = ?", key(id))
    }

    func documentIDs(in zone: CloudZoneID? = nil) throws -> [CloudRecordID] {
        let rows: [[SQLValue]]
        if let zone {
            rows = try db.rows("SELECT zone, name FROM records WHERE zone = ? ORDER BY name", [.text(zone.name)])
        } else {
            rows = try db.rows("SELECT zone, name FROM records ORDER BY zone, name")
        }
        return rows.compactMap { row in
            guard let zone = row[0].text, let name = row[1].text else { return nil }
            return CloudRecordID(zone: CloudZoneID(zone), name: name)
        }
    }

    func mirror(_ id: CloudRecordID) throws -> MirrorRow? {
        guard let row = try db.rows("""
            SELECT type, hlc, device, deleted, key_id, system_fields, digest FROM mirror WHERE zone = ? AND name = ?
            """, key(id)).first else { return nil }
        return mirrorRow(row)
    }

    func putMirror(_ id: CloudRecordID, _ row: MirrorRow) throws {
        try db.run("""
            INSERT INTO mirror(zone, name, type, hlc, device, deleted, key_id, system_fields, digest)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone, name) DO UPDATE SET type = excluded.type, hlc = excluded.hlc, device = excluded.device,
                deleted = excluded.deleted, key_id = excluded.key_id, system_fields = excluded.system_fields,
                digest = excluded.digest
            """, key(id) + [.text(row.type), .text(row.hlc.description), .text(row.device), SQLValue(row.deleted),
                            .text(row.keyID), SQLValue(row.systemFields), .blob(row.digest)])
    }

    func deleteMirror(_ id: CloudRecordID) throws {
        try db.run("DELETE FROM mirror WHERE zone = ? AND name = ?", key(id))
    }

    func deletedMirrorRows() throws -> [(CloudRecordID, MirrorRow)] {
        try db.rows("""
            SELECT type, hlc, device, deleted, key_id, system_fields, digest, zone, name FROM mirror WHERE deleted = 1
            ORDER BY zone, name
            """).compactMap { row in
            guard let zone = row[7].text, let name = row[8].text, let mirror = mirrorRow(row) else { return nil }
            return (CloudRecordID(zone: CloudZoneID(zone), name: name), mirror)
        }
    }

    private func mirrorRow(_ row: [SQLValue]) -> MirrorRow? {
        guard let type = row[0].text, let hlc = row[1].text.flatMap(HLC.init), let device = row[2].text,
              let deleted = row[3].int, let keyID = row[4].text else { return nil }
        return MirrorRow(type: type, hlc: hlc, device: device, deleted: deleted != 0, keyID: keyID,
                         systemFields: row[5].blob, digest: row[6].blob ?? Data())
    }

    func outbox(_ id: CloudRecordID) throws -> OutboxRow? {
        try db.rows("SELECT zone, name, hlc, operation, state, force_asset FROM outbox WHERE zone = ? AND name = ?", key(id))
            .first.flatMap(outboxRow)
    }

    func putOutbox(_ row: OutboxRow) throws {
        try db.run("""
            INSERT INTO outbox(zone, name, hlc, operation, state, force_asset) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(zone, name) DO UPDATE SET hlc = excluded.hlc, operation = excluded.operation,
                state = excluded.state, force_asset = excluded.force_asset
            """, key(row.id) + [.text(row.hlc.description), .text(row.operation.rawValue), .text(row.state.rawValue),
                                SQLValue(row.forceAsset)])
    }

    func deleteOutbox(_ id: CloudRecordID) throws {
        try db.run("DELETE FROM outbox WHERE zone = ? AND name = ?", key(id))
    }

    func outboxRows() throws -> [OutboxRow] {
        try db.rows("SELECT zone, name, hlc, operation, state, force_asset FROM outbox ORDER BY zone, name")
            .compactMap(outboxRow)
    }

    func outboxCount() throws -> Int {
        Int(try db.rows("SELECT COUNT(*) FROM outbox").first?.first?.int ?? 0)
    }

    private func outboxRow(_ row: [SQLValue]) -> OutboxRow? {
        guard let zone = row[0].text, let name = row[1].text, let hlc = row[2].text.flatMap(HLC.init),
              let operation = row[3].text.flatMap(OutboxOperation.init(rawValue:)),
              let state = row[4].text.flatMap(OutboxState.init(rawValue:)), let force = row[5].int else { return nil }
        return OutboxRow(id: CloudRecordID(zone: CloudZoneID(zone), name: name), hlc: hlc, operation: operation, state: state,
                         forceAsset: force != 0)
    }

    func putParked(_ row: ParkedRow) throws {
        let record = try row.record.map { try JSONEncoder().encode($0) }
        try db.run("""
            INSERT INTO parked(zone, name, reason, record) VALUES(?, ?, ?, ?)
            ON CONFLICT(zone, name) DO UPDATE SET reason = excluded.reason, record = excluded.record
            """, key(row.id) + [.text(row.reason.rawValue), SQLValue(record)])
    }

    func parked(_ id: CloudRecordID) throws -> ParkedRow? {
        try db.rows("SELECT zone, name, reason, record FROM parked WHERE zone = ? AND name = ?", key(id))
            .first.flatMap(parkedRow)
    }

    func deleteParked(_ id: CloudRecordID) throws {
        try db.run("DELETE FROM parked WHERE zone = ? AND name = ?", key(id))
    }

    func parkedRows() throws -> [ParkedRow] {
        try db.rows("SELECT zone, name, reason, record FROM parked ORDER BY zone, name").compactMap(parkedRow)
    }

    private func parkedRow(_ row: [SQLValue]) -> ParkedRow? {
        guard let zone = row[0].text, let name = row[1].text,
              let reason = row[2].text.flatMap(ParkReason.init(rawValue:)) else { return nil }
        let record = row[3].blob.flatMap { try? JSONDecoder().decode(CloudRecord.self, from: $0) }
        return ParkedRow(id: CloudRecordID(zone: CloudZoneID(zone), name: name), reason: reason, record: record)
    }

    func clearSyncState(zone: CloudZoneID?) throws {
        for table in ["outbox", "mirror", "parked"] {
            if let zone {
                try db.run("DELETE FROM \(table) WHERE zone = ?", [.text(zone.name)])
            } else {
                try db.run("DELETE FROM \(table)")
            }
        }
    }

    func engineState() throws -> Data? {
        try db.rows("SELECT blob FROM engine_state WHERE id = 1").first?.first?.blob
    }

    func setEngineState(_ data: Data?) throws {
        if let data {
            try db.run("INSERT INTO engine_state(id, blob) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET blob = excluded.blob",
                       [.blob(data)])
        } else {
            try db.run("DELETE FROM engine_state")
        }
    }

    func appendLog(_ entry: CloudDiagnostic, keep: Int) throws {
        try db.run("INSERT INTO log(at, kind, code, count) VALUES(?, ?, ?, ?)",
                   [.real(entry.date.timeIntervalSince1970), .text(entry.kind.rawValue), SQLValue(entry.code),
                    .int(Int64(entry.count))])
        try db.run("DELETE FROM log WHERE id <= (SELECT MAX(id) FROM log) - ?", [.int(Int64(max(1, keep)))])
    }

    func log(limit: Int) throws -> [CloudDiagnostic] {
        let rows = try db.rows("SELECT at, kind, code, count FROM log ORDER BY id DESC LIMIT ?", [.int(Int64(max(0, limit)))])
        let entries = rows.compactMap { row -> CloudDiagnostic? in
            guard let at = row[0].real ?? row[0].int.map({ Double($0) }), let kind = row[1].text.flatMap(CloudDiagnostic.Kind.init),
                  let count = row[3].int else { return nil }
            return CloudDiagnostic(date: Date(timeIntervalSince1970: at), kind: kind, code: row[2].text, count: Int(count))
        }
        return Array(entries.reversed())
    }

    private func key(_ id: CloudRecordID) -> [SQLValue] {
        [.text(id.zone.name), .text(id.name)]
    }
}
