import Foundation
import OpenHumanCore

public enum AttachmentFiles {
    public static let quarantineAttribute = FileQuarantine.attribute

    public static func newQuarantineValue(now: Date = Date(), agent: String = FileQuarantine.agent) -> String {
        FileQuarantine.value(now: now, agent: agent)
    }

    public static func quarantine(of url: URL) -> String? {
        FileQuarantine.read(url)
    }

    public static func setQuarantine(_ value: String, on url: URL) throws {
        try FileQuarantine.write(value, to: url)
    }

    public static func ensureQuarantine(_ url: URL) throws {
        try FileQuarantine.ensure(url)
    }

    @discardableResult
    public static func save(_ source: URL, filename: String, to destination: URL, replacing: Bool = true) throws -> URL {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let target: URL
        if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            target = uniqueURL(in: destination, filename: ReaderFormatting.safeFilename(filename))
        } else if manager.fileExists(atPath: destination.path), !replacing {
            target = uniqueURL(in: destination.deletingLastPathComponent(), filename: destination.lastPathComponent)
        } else {
            target = destination
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        }
        try manager.copyItem(at: source, to: target)
        try setQuarantine(quarantine(of: source) ?? newQuarantineValue(), on: target)
        return target
    }

    public static func uniqueURL(in folder: URL, filename: String) -> URL {
        let manager = FileManager.default
        let ext = (filename as NSString).pathExtension
        let base = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
        var candidate = folder.appendingPathComponent(filename)
        var n = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
