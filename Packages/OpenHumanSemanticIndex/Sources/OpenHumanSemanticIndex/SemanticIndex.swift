import Foundation
import OpenHumanAI

public actor SemanticIndex {
    public enum Location: Sendable, Hashable {
        case directory(URL)
        case inMemory
    }

    public struct Entry: Sendable, Hashable {
        public var mid: Int64
        public var account: Int64
        public var thread: Int64
        public var gmailID: String
        public var internalDate: Date
        public var source: Int
        public var digest: Data

        public init(mid: Int64, account: Int64, thread: Int64, gmailID: String, internalDate: Date, source: Int, digest: Data) {
            self.mid = mid
            self.account = account
            self.thread = thread
            self.gmailID = gmailID
            self.internalDate = internalDate
            self.source = source
            self.digest = digest
        }
    }

    public struct Hit: Sendable, Hashable {
        public var mid: Int64
        public var gmailID: String
        public var thread: Int64
        public var account: Int64
        public var score: Float
    }

    public struct Filter: Sendable, Hashable {
        public var accounts: Set<Int64>?
        public var after: Date?
        public var before: Date?
        public var allowList: Set<Int64>?
        public var limit: Int
        public var perThread: Int
        public var threshold: Float

        public init(accounts: Set<Int64>? = nil, after: Date? = nil, before: Date? = nil, allowList: Set<Int64>? = nil,
                    limit: Int = 200, perThread: Int = 3, threshold: Float = 0) {
            self.accounts = accounts
            self.after = after
            self.before = before
            self.allowList = allowList
            self.limit = limit
            self.perThread = perThread
            self.threshold = threshold
        }
    }

    public static let folderName = "Semantic"
    public static let databaseName = "semantic.sqlite"
    static let format: Int64 = 1

    private struct Slot {
        var entry: Entry
        var dateMS: Int64
        var crc: UInt32
        var embeddedAt: Int64
    }

    public nonisolated let location: Location
    private var db: SidecarDatabase
    private var storage: SlotStorage?
    public private(set) var activeSpace: EmbeddingSpace?
    public nonisolated let openedAfterCleanShutdown: Bool
    private var table: [Slot?] = []
    private var slotByMid: [Int64: Int] = [:]
    private var freeSlots: [Int] = []
    private var isDestroyed = false

    public init(location: Location, now: Date = Date()) throws {
        self.location = location
        let db: SidecarDatabase
        switch location {
        case .inMemory:
            db = try SidecarDatabase(path: ":memory:")
            try Self.createSchema(db)
        case .directory(let directory):
            try Self.prepare(directory)
            db = try Self.openOrRecover(directory, now: now)
        }
        self.db = db
        let meta = try Self.meta(db)
        openedAfterCleanShutdown = meta["clean_shutdown"] != "0"
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('clean_shutdown', '0'), ('format', '1')")
        let loaded = try Self.load(db, location: location, activeID: meta["active_space"])
        var byMid: [Int64: Int] = [:]
        for (index, slot) in loaded.table.enumerated() { if let slot { byMid[slot.entry.mid] = index } }
        activeSpace = loaded.space
        storage = loaded.storage
        table = loaded.table
        freeSlots = loaded.free
        slotByMid = byMid
    }

    public var count: Int { slotByMid.count }

    public func entry(mid: Int64) -> Entry? { slotByMid[mid].flatMap { table[$0]?.entry } }

    public func mids() -> [Int64] { slotByMid.keys.sorted() }

    public var bytesOnDisk: Int64 {
        guard case .directory(let directory) = location else { return 0 }
        let files = [Self.databaseName, Self.databaseName + "-wal"].map { directory.appendingPathComponent($0).path }
        let sizes = files.map { ((try? FileManager.default.attributesOfItem(atPath: $0))?[.size] as? NSNumber)?.int64Value ?? 0 }
        return sizes.reduce(0, +) + (storage?.bytesOnDisk ?? 0)
    }

    public func search(_ vector: [Float], filter: Filter) -> [Hit] {
        guard let space = activeSpace, let storage, !slotByMid.isEmpty, filter.limit > 0 else { return [] }
        let (query, queryScale) = Int8Quantizer.quantize(vector, dimension: space.dimension)
        guard queryScale > 0 else { return [] }
        let afterMS = filter.after.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
        let beforeMS = filter.before.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) }
        var scored: [(score: Float, slot: Int, mid: Int64)] = []
        query.withUnsafeBufferPointer { query in
            for index in table.indices {
                guard let slot = table[index] else { continue }
                if let accounts = filter.accounts, !accounts.contains(slot.entry.account) { continue }
                if let afterMS, slot.dateMS < afterMS { continue }
                if let beforeMS, slot.dateMS >= beforeMS { continue }
                if let allow = filter.allowList, !allow.contains(slot.entry.mid) { continue }
                let score = Int8Quantizer.score(query: query, queryScale: queryScale, slot: storage.pointer(slot: index),
                                                dimension: space.dimension)
                if score >= filter.threshold { scored.append((score, index, slot.entry.mid)) }
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.mid > $1.mid }
        var perThread: [Int64: Int] = [:]
        var hits: [Hit] = []
        for candidate in scored {
            guard let entry = table[candidate.slot]?.entry else { continue }
            let taken = perThread[entry.thread, default: 0]
            guard taken < filter.perThread else { continue }
            perThread[entry.thread] = taken + 1
            hits.append(Hit(mid: entry.mid, gmailID: entry.gmailID, thread: entry.thread, account: entry.account,
                            score: candidate.score))
            if hits.count >= filter.limit { break }
        }
        return hits
    }

    public func vector(mid: Int64) -> [Float]? {
        guard let space = activeSpace, let storage, let slot = slotByMid[mid] else { return nil }
        return Int8Quantizer.decode(storage.pointer(slot: slot), dimension: space.dimension)
    }

    public func storeEpoch() throws -> String? { try Self.meta(db)["store_epoch"] }

    public func setStoreEpoch(_ epoch: String) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('store_epoch', ?)", [.text(epoch)])
    }

    public func activate(_ space: EmbeddingSpace, probes: [[Float]], now: Date = Date()) throws {
        try checkOpen()
        if activeSpace?.id == space.id { return }
        guard space.dimension > 0, space.isConsistent else { throw SidecarError.format("space") }
        try clearSpaces()
        let descriptor = String(decoding: try JSONEncoder().encode(space), as: UTF8.self)
        let stride = Int8Quantizer.stride(dimension: space.dimension)
        let ms = Self.ms(now)
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO spaces (space_id, descriptor, dimension, stride, created_at) VALUES (?, ?, ?, ?, ?)",
                       [.text(space.id), .text(descriptor), .int(Int64(space.dimension)), .int(Int64(stride)), .int(ms)])
            try db.run("INSERT OR REPLACE INTO progress (space_id, watermark_mid, embedded, failed, updated_at) VALUES (?, 0, 0, 0, ?)",
                       [.text(space.id), .int(ms)])
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('active_space', ?)", [.text(space.id)])
            try db.run("DELETE FROM pending_body")
        }
        storage = try Self.makeStorage(location, space: space)
        if case .directory(let directory) = location {
            let data = probes.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
            let url = Self.spaceFolder(directory, space.id).appendingPathComponent("probe.f32")
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            memoryProbes = probes
        }
        activeSpace = space
        table = []
        slotByMid = [:]
        freeSlots = []
    }

    private var memoryProbes: [[Float]]?

    public func probes() -> [[Float]]? {
        guard let space = activeSpace else { return nil }
        guard case .directory(let directory) = location else { return memoryProbes }
        guard let data = try? Data(contentsOf: Self.spaceFolder(directory, space.id).appendingPathComponent("probe.f32")),
              data.count == EmbeddingProbe.sentences.count * space.dimension * 4 else { return nil }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Swift.stride(from: 0, to: values.count, by: space.dimension).map { Array(values[$0..<$0 + space.dimension]) }
    }

    public func adopt(_ space: EmbeddingSpace) throws {
        try checkOpen()
        guard let old = activeSpace, old.id != space.id, old.dimension == space.dimension, space.isConsistent else { return }
        let descriptor = String(decoding: try JSONEncoder().encode(space), as: UTF8.self)
        try db.transaction {
            for name in ["slots", "free_slots", "progress"] {
                try db.run("UPDATE \(name) SET space_id = ? WHERE space_id = ?", [.text(space.id), .text(old.id)])
            }
            try db.run("UPDATE spaces SET space_id = ?, descriptor = ? WHERE space_id = ?",
                       [.text(space.id), .text(descriptor), .text(old.id)])
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('active_space', ?)", [.text(space.id)])
        }
        try storage?.relabel(dimension: space.dimension, spaceID: space.id)
        if case .directory(let directory) = location {
            storage?.close()
            try FileManager.default.moveItem(at: Self.spaceFolder(directory, old.id), to: Self.spaceFolder(directory, space.id))
            storage = try Self.makeStorage(location, space: space)
        }
        activeSpace = space
    }

    public func upsert(_ items: [(entry: Entry, vector: [Float])], now: Date = Date()) throws {
        try checkOpen()
        guard let space = activeSpace, let storage else { throw SidecarError.format("no active space") }
        guard !items.isEmpty else { return }
        var written: [(slot: Int, entry: Entry, crc: UInt32)] = []
        var taken: [Int] = []
        do {
            for item in items {
                let slot: Int
                if let existing = slotByMid[item.entry.mid] {
                    slot = existing
                } else if let free = freeSlots.popLast() {
                    slot = free
                    taken.append(free)
                } else {
                    slot = table.count
                    table.append(nil)
                    taken.append(slot)
                }
                let bytes = Int8Quantizer.encode(item.vector, dimension: space.dimension)
                try storage.write(bytes, slot: slot)
                written.append((slot, item.entry, CRC32.checksum(bytes)))
            }
            try storage.sync()
            let at = Self.ms(now)
            try db.transaction {
                for row in written {
                    let e = row.entry
                    try db.run("""
                        INSERT OR REPLACE INTO slots (space_id, slot, mid, chunk, gmail_message_id, account_id, tid,
                            internal_date, source, text_digest, crc32, embedded_at)
                        VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [.text(space.id), .int(Int64(row.slot)), .int(e.mid), .text(e.gmailID), .int(e.account),
                              .int(e.thread), .int(Self.ms(e.internalDate)), .int(Int64(e.source)), .blob(e.digest),
                              .int(Int64(row.crc)), .int(at)])
                    try db.run("DELETE FROM free_slots WHERE space_id = ? AND slot = ?", [.text(space.id), .int(Int64(row.slot))])
                }
                let added = Set(written.map(\.entry.mid)).subtracting(slotByMid.keys).count
                try db.run("UPDATE progress SET embedded = ?, updated_at = ? WHERE space_id = ?",
                           [.int(Int64(slotByMid.count + added)), .int(at), .text(space.id)])
            }
            for row in written {
                table[row.slot] = Slot(entry: row.entry, dateMS: Self.ms(row.entry.internalDate), crc: row.crc, embeddedAt: at)
                slotByMid[row.entry.mid] = row.slot
            }
        } catch {
            freeSlots.append(contentsOf: taken)
            throw error
        }
    }

    public func remove(mids: [Int64]) throws {
        try checkOpen()
        guard let space = activeSpace, let storage else { return }
        let found = mids.compactMap { mid in slotByMid[mid].map { (mid: mid, slot: $0) } }
        guard !found.isEmpty else { return }
        for item in found { try storage.zero(slot: item.slot) }
        try storage.sync()
        try db.transaction {
            for item in found {
                try db.run("DELETE FROM slots WHERE space_id = ? AND slot = ?", [.text(space.id), .int(Int64(item.slot))])
                try db.run("INSERT OR IGNORE INTO free_slots (space_id, slot) VALUES (?, ?)", [.text(space.id), .int(Int64(item.slot))])
            }
            try db.run("UPDATE progress SET embedded = ? WHERE space_id = ?",
                       [.int(Int64(slotByMid.count - found.count)), .text(space.id)])
        }
        for item in found {
            table[item.slot] = nil
            slotByMid[item.mid] = nil
            freeSlots.append(item.slot)
        }
    }

    public func removeAccount(_ account: Int64) throws {
        try checkOpen()
        try remove(mids: table.compactMap { $0?.entry }.filter { $0.account == account }.map(\.mid))
        try db.run("DELETE FROM pending_body WHERE account_id = ?", [.int(account)])
    }

    public func verifyRecentSlots(since: Date) throws -> [Int64] {
        guard let storage else { return [] }
        let sinceMS = Self.ms(since)
        var damaged: [Int64] = []
        for index in table.indices {
            guard let slot = table[index], slot.embeddedAt >= sinceMS else { continue }
            let bytes = Int8Quantizer.stride(dimension: activeSpace?.dimension ?? 0)
            if CRC32.checksum(storage.pointer(slot: index), count: bytes) != slot.crc { damaged.append(slot.entry.mid) }
        }
        try remove(mids: damaged)
        return damaged
    }

    public func watermark() throws -> Int64 {
        guard let space = activeSpace else { return 0 }
        return try db.rows("SELECT watermark_mid FROM progress WHERE space_id = ?", [.text(space.id)]).first?.first?.int ?? 0
    }

    public func setWatermark(_ mid: Int64, now: Date = Date()) throws {
        guard let space = activeSpace else { return }
        try db.run("UPDATE progress SET watermark_mid = ?, updated_at = ? WHERE space_id = ?",
                   [.int(mid), .int(Self.ms(now)), .text(space.id)])
    }

    public func failedCount() throws -> Int {
        guard let space = activeSpace else { return 0 }
        return Int(try db.rows("SELECT failed FROM progress WHERE space_id = ?", [.text(space.id)]).first?.first?.int ?? 0)
    }

    public func addFailed(_ count: Int) throws {
        guard let space = activeSpace, count > 0 else { return }
        try db.run("UPDATE progress SET failed = failed + ? WHERE space_id = ?", [.int(Int64(count)), .text(space.id)])
    }

    public func reconciledAt() throws -> Date? {
        guard let space = activeSpace,
              let value = try db.rows("SELECT reconciled_at FROM progress WHERE space_id = ?", [.text(space.id)]).first?.first,
              !value.isNull else { return nil }
        return Date(timeIntervalSince1970: Double(value.int) / 1000)
    }

    public func setReconciled(_ date: Date) throws {
        guard let space = activeSpace else { return }
        try db.run("UPDATE progress SET reconciled_at = ? WHERE space_id = ?", [.int(Self.ms(date)), .text(space.id)])
    }

    public func addPending(_ items: [(mid: Int64, account: Int64)], now: Date = Date()) throws {
        guard !items.isEmpty else { return }
        try db.transaction {
            for item in items {
                try db.run("INSERT OR IGNORE INTO pending_body (mid, account_id, since) VALUES (?, ?, ?)",
                           [.int(item.mid), .int(item.account), .int(Self.ms(now))])
            }
        }
    }

    public func pendingByAccount() throws -> [Int64: [Int64]] {
        var result: [Int64: [Int64]] = [:]
        for row in try db.rows("SELECT mid, account_id FROM pending_body ORDER BY mid") { result[row[1].int, default: []].append(row[0].int) }
        return result
    }

    public func removePending(_ mids: [Int64]) throws {
        guard !mids.isEmpty else { return }
        try db.transaction {
            for mid in mids { try db.run("DELETE FROM pending_body WHERE mid = ?", [.int(mid)]) }
        }
    }

    public func reset() throws {
        try checkOpen()
        try clearSpaces()
        try db.run("DELETE FROM pending_body")
        try db.run("DELETE FROM meta WHERE key IN ('active_space', 'building_space')")
        activeSpace = nil
        storage = nil
        table = []
        slotByMid = [:]
        freeSlots = []
    }

    public func close() {
        guard !isDestroyed else { return }
        try? db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('clean_shutdown', '1')")
    }

    public func destroy() throws {
        guard !isDestroyed else { return }
        isDestroyed = true
        storage?.close()
        storage = nil
        db.close()
        activeSpace = nil
        table = []
        slotByMid = [:]
        freeSlots = []
        memoryProbes = nil
        if case .directory(let directory) = location, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public var isUsable: Bool { !isDestroyed }

    private func checkOpen() throws {
        if isDestroyed { throw SidecarError.damaged("destroyed") }
    }

    private func clearSpaces() throws {
        storage?.close()
        storage = nil
        try db.transaction {
            for name in ["slots", "free_slots", "spaces", "progress"] { try db.run("DELETE FROM \(name)") }
        }
        if case .directory(let directory) = location { Self.removeSpaceFolders(directory) }
        memoryProbes = nil
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func spaceFolder(_ directory: URL, _ id: String) -> URL {
        directory.appendingPathComponent("space-\(id)", isDirectory: true)
    }

    private static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    private static func openOrRecover(_ directory: URL, now: Date) throws -> SidecarDatabase {
        let url = directory.appendingPathComponent(databaseName)
        do {
            return try openChecked(url)
        } catch {
            let aside = directory.appendingPathComponent("semantic.damaged-\(Int(now.timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: url, to: aside)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
            removeSpaceFolders(directory)
            return try openChecked(url)
        }
    }

    private static func openChecked(_ url: URL) throws -> SidecarDatabase {
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let db = try SidecarDatabase(path: url.path)
        let version = try db.rows("PRAGMA user_version").first?.first?.int ?? 0
        guard version == 0 || version == format else { throw SidecarError.damaged("format") }
        guard try db.rows("PRAGMA quick_check").first?.first?.text == "ok" else { throw SidecarError.damaged("check") }
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA secure_delete = ON;")
        try createSchema(db)
        return db
    }

    private static func createSchema(_ db: SidecarDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS spaces (
              space_id TEXT PRIMARY KEY, descriptor TEXT NOT NULL, dimension INTEGER NOT NULL, stride INTEGER NOT NULL,
              created_at INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS slots (
              space_id TEXT NOT NULL, slot INTEGER NOT NULL, mid INTEGER NOT NULL, chunk INTEGER NOT NULL DEFAULT 0,
              gmail_message_id TEXT NOT NULL, account_id INTEGER NOT NULL, tid INTEGER NOT NULL,
              internal_date INTEGER NOT NULL, source INTEGER NOT NULL, text_digest BLOB NOT NULL, crc32 INTEGER NOT NULL,
              embedded_at INTEGER NOT NULL, PRIMARY KEY (space_id, slot)) WITHOUT ROWID;
            CREATE UNIQUE INDEX IF NOT EXISTS slots_by_mid ON slots (space_id, mid, chunk);
            CREATE TABLE IF NOT EXISTS free_slots (space_id TEXT NOT NULL, slot INTEGER NOT NULL,
              PRIMARY KEY (space_id, slot)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS pending_body (mid INTEGER PRIMARY KEY, account_id INTEGER NOT NULL, since INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS progress (
              space_id TEXT PRIMARY KEY, watermark_mid INTEGER NOT NULL DEFAULT 0, reconciled_at INTEGER,
              embedded INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL) WITHOUT ROWID;
            PRAGMA user_version = 1;
            """)
    }

    private static func meta(_ db: SidecarDatabase) throws -> [String: String] {
        Dictionary(try db.rows("SELECT key, value FROM meta").map { ($0[0].text, $0[1].text) }, uniquingKeysWith: { a, _ in a })
    }

    private static func makeStorage(_ location: Location, space: EmbeddingSpace) throws -> SlotStorage {
        let stride = Int8Quantizer.stride(dimension: space.dimension)
        switch location {
        case .inMemory:
            return MemorySlots(stride: stride)
        case .directory(let directory):
            let folder = spaceFolder(directory, space.id)
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            return try MappedSlotFile(url: folder.appendingPathComponent("vectors.i8"), dimension: space.dimension,
                                      stride: stride, spaceID: space.id)
        }
    }

    private static func removeSpaceFolders(_ directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("space-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private struct Loaded {
        var space: EmbeddingSpace?
        var storage: SlotStorage?
        var table: [Slot?] = []
        var free: [Int] = []
    }

    private static func load(_ db: SidecarDatabase, location: Location, activeID: String?) throws -> Loaded {
        guard let activeID else { return Loaded() }
        guard let row = try db.rows("SELECT descriptor FROM spaces WHERE space_id = ?", [.text(activeID)]).first,
              let space = try? JSONDecoder().decode(EmbeddingSpace.self, from: Data(row[0].text.utf8)),
              space.isConsistent, space.id == activeID,
              let storage = try? makeStorage(location, space: space) else {
            try db.transaction {
                for name in ["slots", "free_slots", "spaces", "progress"] { try db.run("DELETE FROM \(name)") }
                try db.run("DELETE FROM meta WHERE key = 'active_space'")
                try db.run("DELETE FROM pending_body")
            }
            if case .directory(let directory) = location { removeSpaceFolders(directory) }
            return Loaded()
        }
        var table: [Slot?] = []
        for row in try db.rows("""
            SELECT slot, mid, gmail_message_id, account_id, tid, internal_date, source, text_digest, crc32, embedded_at
            FROM slots WHERE space_id = ? AND chunk = 0
            """, [.text(activeID)]) {
            let index = Int(row[0].int)
            guard index >= 0, index < storage.capacity else { continue }
            if table.count <= index { table.append(contentsOf: repeatElement(nil, count: index + 1 - table.count)) }
            let date = Date(timeIntervalSince1970: Double(row[5].int) / 1000)
            table[index] = Slot(entry: Entry(mid: row[1].int, account: row[3].int, thread: row[4].int, gmailID: row[2].text,
                                             internalDate: date, source: Int(row[6].int), digest: row[7].blob),
                                dateMS: row[5].int, crc: UInt32(truncatingIfNeeded: row[8].int), embeddedAt: row[9].int)
        }
        var free = Set(try db.rows("SELECT slot FROM free_slots WHERE space_id = ?", [.text(activeID)]).map { Int($0[0].int) })
        for index in table.indices where table[index] == nil { free.insert(index) }
        return Loaded(space: space, storage: storage, table: table, free: free.filter { $0 < table.count }.sorted(by: >))
    }
}
