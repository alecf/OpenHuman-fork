import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FileQuarantine {
    public static let attribute = "com.apple.quarantine"
    public static let flags = "0083"
    public static let agent = "OpenHuman Mail"

    public static func value(now: Date = Date(), agent: String = FileQuarantine.agent) -> String {
        let time = String(format: "%08x", UInt32(truncatingIfNeeded: Int(now.timeIntervalSince1970)))
        return "\(flags);\(time);\(agent);\(UUID().uuidString)"
    }

    public static func read(_ url: URL) -> String? {
        #if canImport(Darwin)
        return url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, attribute, &buffer, size, 0, 0)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
        #else
        return nil
        #endif
    }

    public static func write(_ value: String, to url: URL) throws {
        #if canImport(Darwin)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let bytes = Array(value.utf8)
            return setxattr(path, attribute, bytes, bytes.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        #endif
    }

    public static func ensure(_ url: URL, now: Date = Date()) throws {
        if read(url) == nil { try write(value(now: now), to: url) }
    }
}
