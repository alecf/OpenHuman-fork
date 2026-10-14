import Foundation
import Synchronization

public protocol ThemeFolderWatching: Sendable {
    func changes() -> AsyncStream<Void>
}

public final class ManualThemeFolderWatcher: ThemeFolderWatching {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    public init() {}

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.continuations.withLock { _ = $0.removeValue(forKey: id) } }
        return stream
    }

    public func trigger() {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield() }
    }
}

public struct ThemeFolder: Sendable, Hashable {
    public static let maxFiles = 200

    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenHuman/Mail/Themes", isDirectory: true)
    }

    public var accentsURL: URL { url.appendingPathComponent("accents", isDirectory: true) }

    public func create() throws {
        try FileManager.default.createDirectory(at: accentsURL, withIntermediateDirectories: true)
    }

    public func jsonFiles() -> [URL] {
        var found: [URL] = []
        for dir in [url, accentsURL] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            found += items.filter { $0.pathExtension.lowercased() == "json" }
        }
        return Array(found.sorted { $0.path < $1.path }.prefix(Self.maxFiles))
    }
}

struct FileStamp: Hashable, Sendable {
    let size: Int
    let modified: Date?
}

public actor ThemeLoader {
    public let folder: ThemeFolder
    let registry: TokenRegistry
    private var cache: [URL: (stamp: FileStamp, data: Data?, result: ValidationResult)] = [:]
    public private(set) var validationCount = 0
    private var scanCount = 0

    public init(folder: ThemeFolder, registry: TokenRegistry = .v1) {
        self.folder = folder
        self.registry = registry
    }

    public func scan() -> [(source: URL, result: ValidationResult)] {
        var results: [(URL, ValidationResult)] = []
        var seen = Set<URL>()
        for url in folder.jsonFiles() {
            seen.insert(url)
            results.append((url, load(url)))
        }
        cache = cache.filter { seen.contains($0.key) }
        return results
    }

    public func library(base: ThemeLibrary = .builtIn) -> ThemeLibrary {
        var library = base
        library.replaceUserFiles(scan())
        return library
    }

    public func numberedLibrary(base: ThemeLibrary = .builtIn) -> (number: Int, library: ThemeLibrary) {
        scanCount += 1
        return (scanCount, library(base: base))
    }

    public func importFile(from source: URL) throws -> (url: URL, result: ValidationResult) {
        try folder.importFile(from: source, registry: registry)
    }

    public func write(themeData data: Data) throws -> URL {
        try folder.write(themeData: data, registry: registry)
    }

    private func load(_ url: URL) -> ValidationResult {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let stamp = FileStamp(size: values?.fileSize ?? -1, modified: values?.contentModificationDate)
        if let cached = cache[url], cached.stamp == stamp { return cached.result }
        if values?.isSymbolicLink == true || values?.isRegularFile != true {
            return remember(url, stamp, nil, refused(.unreadable, "symbolic links and special files are not loaded"))
        }
        if stamp.size > ThemeValidator.maxFileSize {
            return remember(url, stamp, nil, refused(.tooLarge, "file is \(stamp.size) bytes; the limit is \(ThemeValidator.maxFileSize)"))
        }
        guard let data = Self.read(url, limit: ThemeValidator.maxFileSize + 1) else {
            return remember(url, stamp, nil, refused(.unreadable, "could not be read"))
        }
        if let cached = cache[url], cached.data == data { return remember(url, stamp, data, cached.result) }
        validationCount += 1
        return remember(url, stamp, data, ThemeValidator.validate(data: data, registry: registry))
    }

    private func remember(_ url: URL, _ stamp: FileStamp, _ data: Data?, _ result: ValidationResult) -> ValidationResult {
        cache[url] = (stamp, data, result)
        return result
    }

    private func refused(_ code: ThemeIssue.Code, _ message: String) -> ValidationResult {
        ValidationResult(file: nil, issues: [.refused(code, "", message)])
    }

    static func read(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit) ?? Data()
    }
}

public enum ThemeFileError: Error, Sendable, Equatable {
    case refused([ThemeIssue])
    case unreadable
    case writeFailed
}

extension ThemeFolder {
    public func importFile(from source: URL, registry: TokenRegistry = .v1) throws -> (url: URL, result: ValidationResult) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ThemeValidator.maxFileSize else {
            throw ThemeFileError.refused([.refused(.tooLarge, "", "file is \(size) bytes; the limit is \(ThemeValidator.maxFileSize)")])
        }
        guard let data = ThemeLoader.read(source, limit: ThemeValidator.maxFileSize + 1) else { throw ThemeFileError.unreadable }
        let result = ThemeValidator.validate(data: data, registry: registry)
        guard let file = result.file else { throw ThemeFileError.refused(result.issues) }
        try create()
        let destination = (file.kind == .accent ? accentsURL : url).appendingPathComponent(file.id + ".json")
        do { try data.write(to: destination, options: .atomic) } catch { throw ThemeFileError.writeFailed }
        return (destination, result)
    }

    public func write(themeData data: Data, registry: TokenRegistry = .v1) throws -> URL {
        let result = ThemeValidator.validate(data: data, registry: registry)
        guard let file = result.file else { throw ThemeFileError.refused(result.issues) }
        try create()
        let destination = url.appendingPathComponent(file.id + ".json")
        do { try data.write(to: destination, options: .atomic) } catch { throw ThemeFileError.writeFailed }
        return destination
    }
}

public enum ThemeExport {
    public static func customizations(named name: String, baseTheme: ThemeSummary, preferences: ThemePreferences) -> Data {
        var root: [String: Any] = [
            "format": ThemeFile.Kind.theme.rawValue,
            "formatVersion": ThemeValidator.supportedFormatVersion,
            "id": "user." + slug(name),
            "name": String(name.prefix(ThemeValidator.maxNameLength)),
            "appearance": baseTheme.appearance.rawValue,
            "extends": baseTheme.id,
        ]
        if let accent = preferences.accentID { root["defaultAccent"] = accent }
        var typography: [String: Any] = [:]
        var family: [String: Any] = [:]
        if let ui = preferences.uiFont { family["ui"] = ui.token }
        if let reader = preferences.readerFont { family["reader"] = reader.token }
        if !family.isEmpty { typography["family"] = family }
        if let size = preferences.clampedReaderTextSize {
            typography["styles"] = ["reader": ["size": size, "lineHeight": ThemePreferences.readerLineHeight(for: size)]]
        }
        if !typography.isEmpty { root["typography"] = typography }
        if let colors = preferences.emailColors { root["reader"] = ["emailColors": colors.rawValue] }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    public static func flattened(_ tokens: ThemeTokens, id: String, name: String, appearance: ThemeFile.Appearance,
                                 defaultAccent: String? = nil, registry: TokenRegistry = .v1) -> Data {
        var root: [String: Any] = [
            "format": ThemeFile.Kind.theme.rawValue, "formatVersion": ThemeValidator.supportedFormatVersion,
            "id": id, "name": name, "appearance": appearance.rawValue, "extends": NSNull(),
        ]
        if let defaultAccent { root["defaultAccent"] = defaultAccent }
        for entry in registry.entries where entry.layer != .accent {
            guard let value = tokens.value(forKey: entry.key) else { continue }
            insert(literal(value), at: entry.path, into: &root)
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func literal(_ value: TokenValue) -> Any {
        switch value {
        case .color(let c): return c.literal
        case .shadow(let s): return s.layers.isEmpty ? "none" : s.literal
        case .number(let n), .duration(let n): return n
        case .percent(let p): return "\(ThemeColor.shortNumber(p))%"
        case .emailColors(let e): return e.rawValue
        case .fontFamily(let f): return f.token
        case .motion(let m):
            var dict: [String: Any] = ["duration": m.durationMs]
            if let easing = m.easing.literal { dict["easing"] = easing }
            return dict
        case .typography(let t):
            return ["size": t.size, "lineHeight": t.lineHeight, "weight": t.weight, "trackingEm": t.trackingEm,
                    "numerals": t.monospacedDigits ? "tabular" : "proportional", "family": t.role.rawValue]
        }
    }

    static func insert(_ value: Any, at path: [String], into dict: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            dict[first] = value
            return
        }
        var child = dict[first] as? [String: Any] ?? [:]
        insert(value, at: Array(path.dropFirst()), into: &child)
        dict[first] = child
    }

    public static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "custom" : String(out.prefix(40))
    }
}
