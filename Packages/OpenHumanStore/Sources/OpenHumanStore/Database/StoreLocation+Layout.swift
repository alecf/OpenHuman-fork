import Foundation

extension StoreLocation {
    public static func resolve(home: String? = nil) throws -> StoreLocation {
        if let home, !home.isEmpty {
            return StoreLocation(directory: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return StoreLocation(directory: support.appendingPathComponent("OpenHuman", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true))
    }

    public var logsDirectory: URL { directory.appendingPathComponent("Logs", isDirectory: true) }

    func createDirectories() throws {
        let fm = FileManager.default
        for dir in [directory, attachmentsDirectory, draftsDirectory, logsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        Self.excludeFromBackup(attachmentsDirectory)
    }

    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        #endif
    }

    func hardenFilePermissions() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
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
