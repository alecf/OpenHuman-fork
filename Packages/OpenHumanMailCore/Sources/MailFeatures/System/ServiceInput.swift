// Why: the pasteboard is untrusted, so text is plain only, newlines normalized, control characters stripped, sizes capped
import Foundation
import OpenHumanLinks

public enum ServiceInput {
    public static let maxBodyBytes = LinkGrammar.maxBodyBytes
    public static let maxSearchCharacters = 512
    public static let maxFiles = 20

    public static func clean(_ raw: String) -> String? {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = String(String.UnicodeScalarView(unified.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        }))
        var lines = kept.components(separatedBy: "\n")
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    public static func body(_ raw: String, maxBytes: Int = maxBodyBytes) -> (text: String, wasCut: Bool)? {
        guard let text = clean(raw) else { return nil }
        let (prefix, wasCut) = prefix(text, maxUTF8: maxBytes)
        return prefix.isEmpty ? nil : (prefix, wasCut)
    }

    public static func searchQuery(_ raw: String, maxCharacters: Int = maxSearchCharacters) -> String? {
        guard let text = clean(raw) else { return nil }
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let capped = String(line.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    static func prefix(_ text: String, maxUTF8 bytes: Int) -> (String, Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > bytes { break }
            used += size
            end = text.index(after: index)
        }
        return (String(text[..<end]), true)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0.isWhitespace }
    }

    public struct FileSelection: Equatable, Sendable {
        public var files: [URL] = []
        public var foldersSkipped = 0
        public var unreadableSkipped = 0

        public init(files: [URL] = [], foldersSkipped: Int = 0, unreadableSkipped: Int = 0) {
            self.files = files
            self.foldersSkipped = foldersSkipped
            self.unreadableSkipped = unreadableSkipped
        }
    }

    public static func files(_ urls: [URL], fileManager: FileManager = .default) -> FileSelection {
        var selection = FileSelection()
        for url in urls {
            guard url.isFileURL else {
                selection.unreadableSkipped += 1
                continue
            }
            let resolved = url.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true || values?.isPackage == true {
                selection.foldersSkipped += 1
            } else if values?.isRegularFile == true, fileManager.isReadableFile(atPath: resolved.path) {
                selection.files.append(resolved)
            } else {
                selection.unreadableSkipped += 1
            }
        }
        return selection
    }
}
