import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Why: a suite named by a path is written to that plist at once, while cfprefsd writes a suite in
// ~/Library/Preferences later and puts an empty plist back seconds after it is removed
public final class ScopedDefaults: UserDefaults {
    public let name: String

    public convenience init(_ prefix: String) {
        self.init(prefix, in: ScopedDefaults.folder)
    }

    init(_ prefix: String, in folder: URL) {
        name = folder.appendingPathComponent("\(prefix).\(UUID().uuidString)", isDirectory: false).path
        super.init(suiteName: name)!
    }

    var plist: URL { URL(fileURLWithPath: "\(name).plist", isDirectory: false) }

    public func cleanup() { Self.remove(name, from: self) }

    // Why: a change notification about a deallocating instance could outlive it, so another instance removes the domain
    deinit { Self.remove(name, from: UserDefaults(suiteName: name)) }

    private static func remove(_ name: String, from defaults: UserDefaults?) {
        defaults?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: "\(name).plist")
    }

    // Why: the suites of a process share a folder that goes when it exits, or with the next process after a crash
    static let folder: URL = {
        let folder = TemporaryDirectory.processScoped("oh-defaults-")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = atexit { ScopedDefaults.removeFolder() }
        return folder
    }()

    private static func removeFolder() { removeAll(in: folder) }

    // Why: an emptied domain writes nothing when its owner removes it later, so the folder stays gone
    static func removeAll(in folder: URL) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".plist") {
            let name = folder.appendingPathComponent(String(file.dropLast(".plist".count)), isDirectory: false).path
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        try? fm.removeItem(at: folder)
    }
}
