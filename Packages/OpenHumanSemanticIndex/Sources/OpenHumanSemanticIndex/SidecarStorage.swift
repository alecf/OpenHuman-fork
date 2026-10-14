import Darwin
import Foundation
import SQLite3

enum SidecarError: Error, Equatable {
    case open(Int32), statement(Int32), damaged(String), io(Int32), format(String)
}

enum SQLValue: Sendable, Hashable {
    case int(Int64), real(Double), text(String), blob(Data), null

    var int: Int64 { if case .int(let v) = self { return v }; if case .real(let v) = self { return Int64(v) }; return 0 }
    var text: String { if case .text(let v) = self { return v }; return "" }
    var blob: Data { if case .blob(let v) = self { return v }; return Data() }
    var isNull: Bool { self == .null }
}

final class SidecarDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, handle != nil else {
            sqlite3_close_v2(handle)
            handle = nil
            throw SidecarError.open(status)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close_v2(handle) }

    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SidecarError.statement(sqlite3_errcode(handle)) }
    }

    func run(_ sql: String, _ arguments: [SQLValue] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw SidecarError.statement(status) }
    }

    func rows(_ sql: String, _ arguments: [SQLValue] = []) throws -> [[SQLValue]] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var result: [[SQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SidecarError.statement(status) }
            let columns = sqlite3_column_count(statement)
            result.append((0..<columns).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: return .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
                    return .blob(Data(bytes: bytes, count: count))
                default: return .null
                }
            })
        }
        return result
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SidecarError.statement(status)
        }
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol SlotStorage: AnyObject {
    var stride: Int { get }
    var capacity: Int { get }
    var bytesOnDisk: Int64 { get }
    func ensureCapacity(_ slots: Int) throws
    func write(_ bytes: [UInt8], slot: Int) throws
    func zero(slot: Int) throws
    func sync() throws
    func pointer(slot: Int) -> UnsafeRawPointer
    func relabel(dimension: Int, spaceID: String) throws
    func close()
}

final class MappedSlotFile: SlotStorage {
    static let headerSize = 64
    static let growth = 4 * 1024 * 1024
    let stride: Int
    private(set) var capacity = 0
    private let fd: Int32
    private var isClosed = false
    private var map: UnsafeMutableRawPointer?
    private var mappedLength = 0

    init(url: URL, dimension: Int, stride: Int, spaceID: String) throws {
        self.stride = stride
        let existed = FileManager.default.fileExists(atPath: url.path)
        fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            isClosed = true
            throw SidecarError.io(errno)
        }
        var header = [UInt8](repeating: 0, count: Self.headerSize)
        if existed {
            let read = header.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Self.headerSize, 0) }
            guard read == Self.headerSize, Self.header(dimension: dimension, stride: stride, spaceID: spaceID) == header else {
                throw SidecarError.format("vectors header")
            }
        } else {
            header = Self.header(dimension: dimension, stride: stride, spaceID: spaceID)
            let written = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, Self.headerSize, 0) }
            guard written == Self.headerSize else { throw SidecarError.io(errno) }
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SidecarError.io(errno) }
        capacity = max(0, (Int(info.st_size) - Self.headerSize) / stride)
        try remap()
    }

    deinit { close() }

    static func header(dimension: Int, stride: Int, spaceID: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: headerSize)
        bytes.replaceSubrange(0..<4, with: Array("OHSV".utf8))
        func put(_ value: UInt32, at offset: Int) { withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + 4, with: $0) } }
        put(1, at: 4)
        put(UInt32(dimension), at: 8)
        put(UInt32(stride), at: 12)
        put(1, at: 16)
        let id = Array(spaceID.utf8.prefix(16))
        bytes.replaceSubrange(20..<20 + id.count, with: id)
        return bytes
    }

    var bytesOnDisk: Int64 { Int64(Self.headerSize + capacity * stride) }

    func ensureCapacity(_ slots: Int) throws {
        guard slots > capacity else { return }
        let needed = Self.headerSize + slots * stride
        let size = ((needed + Self.growth - 1) / Self.growth) * Self.growth
        guard ftruncate(fd, off_t(size)) == 0 else { throw SidecarError.io(errno) }
        capacity = (size - Self.headerSize) / stride
        try remap()
    }

    func write(_ bytes: [UInt8], slot: Int) throws {
        try ensureCapacity(slot + 1)
        let offset = off_t(Self.headerSize + slot * stride)
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, min(bytes.count, stride), offset) }
        guard written == min(bytes.count, stride) else { throw SidecarError.io(errno) }
    }

    func zero(slot: Int) throws {
        guard slot < capacity else { return }
        try write([UInt8](repeating: 0, count: stride), slot: slot)
    }

    func sync() throws {
        guard fsync(fd) == 0 else { throw SidecarError.io(errno) }
    }

    func relabel(dimension: Int, spaceID: String) throws {
        let header = Self.header(dimension: dimension, stride: stride, spaceID: spaceID)
        let written = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, Self.headerSize, 0) }
        guard written == Self.headerSize, fsync(fd) == 0 else { throw SidecarError.io(errno) }
    }

    func pointer(slot: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(map!).advanced(by: Self.headerSize + slot * stride)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let map { munmap(map, mappedLength) }
        map = nil
        if fd >= 0 { Darwin.close(fd) }
    }

    private func remap() throws {
        if let map { munmap(map, mappedLength) }
        map = nil
        let length = Self.headerSize + capacity * stride
        let pointer = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0)
        guard let pointer, pointer != UnsafeMutableRawPointer(bitPattern: -1) else { throw SidecarError.io(errno) }
        map = pointer
        mappedLength = length
    }
}

final class MemorySlots: SlotStorage {
    let stride: Int
    private var bytes: UnsafeMutableRawPointer
    private(set) var capacity: Int

    init(stride: Int) {
        self.stride = stride
        capacity = 64
        bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity * stride, alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: capacity * stride)
    }

    deinit { bytes.deallocate() }

    var bytesOnDisk: Int64 { 0 }

    func ensureCapacity(_ slots: Int) throws {
        guard slots > capacity else { return }
        let grown = max(slots, capacity * 2)
        let fresh = UnsafeMutableRawPointer.allocate(byteCount: grown * stride, alignment: 16)
        fresh.initializeMemory(as: UInt8.self, repeating: 0, count: grown * stride)
        fresh.copyMemory(from: bytes, byteCount: capacity * stride)
        bytes.deallocate()
        bytes = fresh
        capacity = grown
    }

    func write(_ data: [UInt8], slot: Int) throws {
        try ensureCapacity(slot + 1)
        data.withUnsafeBytes { bytes.advanced(by: slot * stride).copyMemory(from: $0.baseAddress!, byteCount: min(data.count, stride)) }
    }

    func zero(slot: Int) throws {
        guard slot < capacity else { return }
        bytes.advanced(by: slot * stride).initializeMemory(as: UInt8.self, repeating: 0, count: stride)
    }

    func sync() throws {}
    func relabel(dimension: Int, spaceID: String) throws {}
    func pointer(slot: Int) -> UnsafeRawPointer { UnsafeRawPointer(bytes.advanced(by: slot * stride)) }
    func close() {}
}

enum Int8Quantizer {
    static func stride(dimension: Int) -> Int { ((dimension + 4) + 15) / 16 * 16 }

    static func encode(_ vector: [Float], dimension: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: stride(dimension: dimension))
        let (values, scale) = quantize(vector, dimension: dimension)
        for index in 0..<dimension { bytes[index] = UInt8(bitPattern: values[index]) }
        withUnsafeBytes(of: scale.bitPattern.littleEndian) { bytes.replaceSubrange(dimension..<dimension + 4, with: $0) }
        return bytes
    }

    static func quantize(_ vector: [Float], dimension: Int) -> (values: [Int8], scale: Float) {
        var largest: Float = 0
        for index in 0..<min(dimension, vector.count) where vector[index].isFinite { largest = max(largest, abs(vector[index])) }
        guard largest > 0 else { return ([Int8](repeating: 0, count: dimension), 0) }
        let scale = largest / 127
        var values = [Int8](repeating: 0, count: dimension)
        for index in 0..<min(dimension, vector.count) where vector[index].isFinite {
            values[index] = Int8(max(-127, min(127, (vector[index] / scale).rounded())))
        }
        return (values, scale)
    }

    static func decode(_ pointer: UnsafeRawPointer, dimension: Int) -> [Float] {
        let scale = Float(bitPattern: UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: dimension, as: UInt32.self)))
        let values = pointer.assumingMemoryBound(to: Int8.self)
        return (0..<dimension).map { Float(values[$0]) * scale }
    }

    @inline(__always)
    static func score(query: UnsafeBufferPointer<Int8>, queryScale: Float, slot: UnsafeRawPointer, dimension: Int) -> Float {
        let values = slot.assumingMemoryBound(to: Int8.self)
        var sum: Int32 = 0
        for index in 0..<dimension { sum &+= Int32(query[index]) &* Int32(values[index]) }
        let scale = Float(bitPattern: UInt32(littleEndian: slot.loadUnaligned(fromByteOffset: dimension, as: UInt32.self)))
        return Float(sum) * queryScale * scale
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ pointer: UnsafeRawPointer, count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count { crc = table[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0.baseAddress!, count: $0.count) }
    }
}
