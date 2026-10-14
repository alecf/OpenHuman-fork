import Foundation
@testable import MailTheme

enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let module = root.appendingPathComponent("Packages/OpenHumanMailCore/Sources/MailTheme")
    static let designSpec = root.appendingPathComponent("Packages/OpenHumanMailCore/Tests/MailThemeTests/Fixtures/design-tables.md")

    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}

func themeJSON(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

func userTheme(id: String = "me.test", name: String = "Test", appearance: String = "light",
               extends: Any = "openhuman.light", extra: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = ["format": "openhuman-theme", "formatVersion": 1, "id": id, "name": name,
                                 "appearance": appearance, "extends": extends]
    object.merge(extra) { _, new in new }
    return object
}

func validate(_ object: [String: Any]) -> ValidationResult {
    ThemeValidator.validate(data: themeJSON(object))
}

func validate(_ text: String) -> ValidationResult {
    ThemeValidator.validate(data: Data(text.utf8))
}

extension ValidationResult {
    var codes: Set<ThemeIssue.Code> { Set(issues.map(\.code)) }
}

func markdownTable(in text: String, after heading: String) -> [[String]] {
    guard let range = text.range(of: heading) else { return [] }
    var rows: [[String]] = []
    var started = false
    for line in text[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") {
            started = true
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
            rows.append(cells)
        } else if started {
            break
        }
    }
    return Array(rows.dropFirst())
}

func unticked(_ cell: String) -> String { cell.replacingOccurrences(of: "`", with: "") }
