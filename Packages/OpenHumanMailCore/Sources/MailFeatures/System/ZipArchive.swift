import Foundation

public struct ZipArchive {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private var body = Data()
    private var entries: [Entry] = []

    public init() {}

    public var count: Int { entries.count }

    public mutating func add(name: String, data: Data, modified: Date = Date()) {
        let (dosDate, dosTime) = Self.dos(modified)
        let entry = Entry(name: Array(name.utf8), crc: Self.crc32(data), size: UInt32(data.count),
                          offset: UInt32(body.count), dosTime: dosTime, dosDate: dosDate)
        body.append(le32(0x0403_4B50))
        body.append(le16(20))
        body.append(le16(0x0800))
        body.append(le16(0))
        body.append(le16(entry.dosTime))
        body.append(le16(entry.dosDate))
        body.append(le32(entry.crc))
        body.append(le32(entry.size))
        body.append(le32(entry.size))
        body.append(le16(UInt16(entry.name.count)))
        body.append(le16(0))
        body.append(contentsOf: entry.name)
        body.append(data)
        entries.append(entry)
    }

    public mutating func add(name: String, text: String, modified: Date = Date()) {
        add(name: name, data: Data(text.utf8), modified: modified)
    }

    public func data() -> Data {
        var out = body
        let directoryStart = out.count
        for entry in entries {
            out.append(le32(0x0201_4B50))
            out.append(le16(20))
            out.append(le16(20))
            out.append(le16(0x0800))
            out.append(le16(0))
            out.append(le16(entry.dosTime))
            out.append(le16(entry.dosDate))
            out.append(le32(entry.crc))
            out.append(le32(entry.size))
            out.append(le32(entry.size))
            out.append(le16(UInt16(entry.name.count)))
            out.append(le16(0))
            out.append(le16(0))
            out.append(le16(0))
            out.append(le16(0))
            out.append(le32(0))
            out.append(le32(entry.offset))
            out.append(contentsOf: entry.name)
        }
        let directorySize = out.count - directoryStart
        out.append(le32(0x0605_4B50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries.count)))
        out.append(le16(UInt16(entries.count)))
        out.append(le32(UInt32(directorySize)))
        out.append(le32(UInt32(directoryStart)))
        out.append(le16(0))
        return out
    }

    public static func read(_ data: Data) -> [String: Data]? {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var position = 0
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        while position + 30 <= bytes.count, u32(position) == 0x0403_4B50 {
            guard u16(position + 8) == 0 else { return nil }
            let size = u32(position + 18)
            let nameLength = u16(position + 26), extraLength = u16(position + 28)
            let nameStart = position + 30
            let dataStart = nameStart + nameLength + extraLength
            guard dataStart + size <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            result[name] = Data(bytes[dataStart..<(dataStart + size)])
            position = dataStart + size
        }
        return result
    }

    private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    static func dos(_ date: Date) -> (date: UInt16, time: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980)) - 1980
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        return (day, time)
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
