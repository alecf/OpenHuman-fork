import Foundation
import OpenHumanLinks

public struct DevChecklistItem: Identifiable, Sendable, Hashable {
    public enum Requirement: String, Sendable, Hashable, Codable, CaseIterable {
        case fake
        case realReadOnly = "real-readonly"
        case realWrite = "real-write"
    }

    public let id: String
    public let area: String
    public let title: String
    public let steps: [String]
    public let deepLink: String?
    public let expected: String
    public let requires: Requirement
    public let addedIn: String

    public init(id: String, area: String, title: String, steps: [String], deepLink: String? = nil, expected: String,
                requires: Requirement, addedIn: String = "") {
        self.id = id
        self.area = area
        self.title = title
        self.steps = steps
        self.deepLink = deepLink
        self.expected = expected
        self.requires = requires
        self.addedIn = addedIn
    }
}

public struct DevChecklist: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable, Codable { case bundled, override, none }

    public let items: [DevChecklistItem]
    public let source: Source
    public let issues: [String]

    public init(items: [DevChecklistItem], source: Source, issues: [String] = []) {
        self.items = items
        self.source = source
        self.issues = issues
    }
}

public enum DevChecklistLoader {
    public static let format = "openhuman-dev-checklist"
    public static let maxFileBytes = 512 * 1024
    public static let maxItems = 700
    public static let maxDepth = 8
    public static let maxSteps = 12
    static let maxID = 64, maxArea = 60, maxTitle = 200, maxStep = 300, maxExpected = 400, maxAddedIn = 32
    static let maxLinkBytes = 2048

    public static func load(bundled: URL?, override: URL?, fileManager: FileManager = .default) -> DevChecklist {
        var notes: [String] = []
        if let override, fileManager.fileExists(atPath: override.path) {
            switch read(override).flatMap(decode) {
            case .success(let result):
                return DevChecklist(items: result.items, source: .override, issues: result.issues)
            case .failure(let problem):
                notes.append("Override checklist ignored: \(problem.text)")
            }
        }
        guard let bundled else { return DevChecklist(items: [], source: .none, issues: notes + ["No checklist file."]) }
        switch read(bundled).flatMap(decode) {
        case .success(let result):
            return DevChecklist(items: result.items, source: .bundled, issues: notes + result.issues)
        case .failure(let problem):
            return DevChecklist(items: [], source: .none, issues: notes + ["Bundled checklist unusable: \(problem.text)"])
        }
    }

    public struct Problem: Error, Equatable, Sendable {
        public let text: String
        init(_ text: String) { self.text = text }
    }

    static func read(_ url: URL) -> Result<Data, Problem> {
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxFileBytes else { return .failure(Problem("file is larger than \(maxFileBytes / 1024) KB")) }
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(Problem("file could not be read"))
        }
    }

    public static func decode(_ data: Data) -> Result<(items: [DevChecklistItem], issues: [String]), Problem> {
        guard data.count <= maxFileBytes else { return .failure(Problem("file is larger than \(maxFileBytes / 1024) KB")) }
        guard nestingDepth(data) <= maxDepth else { return .failure(Problem("JSON nested deeper than \(maxDepth) levels")) }
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return .failure(Problem("not valid JSON")) }
        let rawItems: [Any]
        if let object = root as? [String: Any] {
            if let declared = object["format"], (declared as? String) != Self.format {
                return .failure(Problem("format is not \"\(Self.format)\""))
            }
            guard let items = object["items"] as? [Any] else { return .failure(Problem("no \"items\" array")) }
            rawItems = items
        } else if let items = root as? [Any] {
            rawItems = items
        } else {
            return .failure(Problem("top level must be an object or an array"))
        }

        var items: [DevChecklistItem] = []
        var issues: [String] = []
        var seen = Set<String>()
        for (index, raw) in rawItems.enumerated() {
            guard items.count < maxItems else {
                issues.append("Only the first \(maxItems) items are used.")
                break
            }
            switch item(raw) {
            case .success(let (item, linkDropped)):
                guard seen.insert(item.id).inserted else {
                    issues.append("Item \(index + 1) skipped: duplicate id \(item.id)")
                    continue
                }
                if linkDropped { issues.append("Item \(item.id): deep link dropped (not a valid openhuman:// link)") }
                items.append(item)
            case .failure(let problem):
                issues.append("Item \(index + 1) skipped: \(problem.text)")
            }
        }
        return .success((items, issues))
    }

    static func item(_ raw: Any) -> Result<(DevChecklistItem, linkDropped: Bool), Problem> {
        guard let fields = raw as? [String: Any] else { return .failure(Problem("not an object")) }
        guard let id = fields["id"] as? String, isValidID(id) else {
            return .failure(Problem("id must be 1-\(maxID) letters, digits, '.', '_' or '-'"))
        }
        guard let area = text(fields["area"], max: maxArea) else { return .failure(Problem("\(id): missing area")) }
        guard let title = text(fields["title"], max: maxTitle) else { return .failure(Problem("\(id): missing title")) }
        guard let rawSteps = fields["steps"] as? [Any], !rawSteps.isEmpty, rawSteps.count <= maxSteps else {
            return .failure(Problem("\(id): steps must be 1-\(maxSteps) strings"))
        }
        var steps: [String] = []
        for step in rawSteps {
            guard let line = text(step, max: maxStep) else { return .failure(Problem("\(id): a step is not text")) }
            steps.append(line)
        }
        guard let expected = text(fields["expected"], max: maxExpected) else {
            return .failure(Problem("\(id): missing expected"))
        }
        guard let requiresText = fields["requires"] as? String,
              let requires = DevChecklistItem.Requirement(rawValue: requiresText)
        else { return .failure(Problem("\(id): requires must be \"fake\", \"real-readonly\" or \"real-write\"")) }
        let addedIn = text(fields["addedIn"], max: maxAddedIn) ?? ""

        var deepLink: String?
        var linkDropped = false
        if let link = fields["deepLink"], !(link is NSNull) {
            if let string = link as? String, string.utf8.count <= maxLinkBytes, case .success = MailLinkParser.parse(string: string) {
                deepLink = string
            } else {
                linkDropped = true
            }
        }
        let item = DevChecklistItem(id: id, area: area, title: title, steps: steps, deepLink: deepLink,
                                    expected: expected, requires: requires, addedIn: addedIn)
        return .success((item, linkDropped))
    }

    static func isValidID(_ id: String) -> Bool {
        guard (1...maxID).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    public static func text(_ value: Any?, max: Int) -> String? {
        guard let string = value as? String else { return nil }
        let cleaned = clean(string, max: max)
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func clean(_ string: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in string.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
                if scalar == "\n" || scalar == "\t" || scalar == "\r" {
                    if !lastWasSpace { out.append(" ") }
                    lastWasSpace = true
                }
                continue
            case .spaceSeparator:
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            default:
                out.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespaces)
        return trimmed.count > max ? String(trimmed.prefix(max - 1)) + "…" : trimmed
    }

    static func nestingDepth(_ data: Data) -> Int {
        var depth = 0, deepest = 0
        var inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = Swift.max(deepest, depth)
                if deepest > maxDepth { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return deepest
    }
}
