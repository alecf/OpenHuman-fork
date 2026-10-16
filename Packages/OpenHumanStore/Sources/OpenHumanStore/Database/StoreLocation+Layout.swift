import Foundation

extension StoreFilePolicy {
    public static let standard = StoreFilePolicy(protection: nil, excludesStoreFromBackup: false)
    // Why: a background refresh opens the store while the phone is locked, and the store is rebuildable from Gmail
    public static let phone = StoreFilePolicy(protection: .untilFirstUnlock, excludesStoreFromBackup: true)

    public static var platformDefault: StoreFilePolicy {
        #if os(iOS)
        .phone
        #else
        .standard
        #endif
    }
}

extension StoreLocation {
    public static func resolve(home: String? = nil) throws -> StoreLocation {
        try resolve(home: home, files: .platformDefault,
                    applicationSupport: try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                    appropriateFor: nil, create: false))
    }

    public static func resolve(home: String?, files: StoreFilePolicy,
                               applicationSupport: @autoclosure () throws -> URL) rethrows -> StoreLocation {
        if let home, !home.isEmpty {
            return StoreLocation(directory: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true),
                                 files: files)
        }
        return StoreLocation(directory: try applicationSupport().appendingPathComponent("OpenHuman", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true), files: files)
    }

    public var logsDirectory: URL { directory.appendingPathComponent("Logs", isDirectory: true) }

    var createdDirectories: [URL] { [directory, attachmentsDirectory, draftsDirectory, logsDirectory] }

    var databaseFiles: [URL] { ["", "-wal", "-shm"].map { URL(fileURLWithPath: databaseURL.path + $0) } }

    var backupExclusions: [URL] {
        files.excludesStoreFromBackup ? createdDirectories + databaseFiles : [attachmentsDirectory]
    }

    var protectedItems: [URL] { files.protection == nil ? [] : createdDirectories + databaseFiles }

    func createDirectories() throws {
        let fm = FileManager.default
        for dir in createdDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        applyFilePolicy(to: createdDirectories)
    }

    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        #endif
    }

    static func protect(_ url: URL, _ protection: StoreFileProtection) {
        #if os(iOS)
        switch protection {
        case .untilFirstUnlock:
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: url.path)
        }
        #endif
    }

    func applyFilePolicy(to urls: [URL]) {
        let fm = FileManager.default
        let excluded = Set(backupExclusions), protected = Set(protectedItems)
        for url in urls where fm.fileExists(atPath: url.path) {
            if excluded.contains(url) { Self.excludeFromBackup(url) }
            if let protection = files.protection, protected.contains(url) { Self.protect(url, protection) }
        }
    }

    func hardenFilePermissions() {
        let fm = FileManager.default
        for url in databaseFiles where fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        applyFilePolicy(to: databaseFiles)
    }

    public static func sanitizedFilename(_ raw: String, partID: String) -> String {
        let removed: Set<Character> = ["/", "\\", ":"]
        var cleaned = String(raw.unicodeScalars.filter { scalar in
            !scalar.properties.generalCategory.isControl && !removed.contains(Character(scalar))
        }.map(Character.init))
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "attachment-\(partID)" }
        let limit = 120
        if cleaned.utf8.count > limit {
            var stem = cleaned
            var ext = ""
            if let dot = cleaned.lastIndex(of: "."), cleaned.distance(from: dot, to: cleaned.endIndex) > 1,
               cleaned[dot...].utf8.count <= 20 {
                ext = String(cleaned[dot...])
                stem = String(cleaned[..<dot])
            }
            while (stem.utf8.count + ext.utf8.count) > limit, !stem.isEmpty { stem.removeLast() }
            cleaned = stem + ext
            if stem.isEmpty { return "attachment-\(partID)" }
        }
        return cleaned
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        switch self {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse: return true
        default: return false
        }
    }
}
