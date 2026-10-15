import Foundation

public enum PromptName: String, Sendable, Hashable, CaseIterable {
    case summarizeThread = "summarize.thread"
    case summarizeChunk = "summarize.chunk"
    case summarizeReduce = "summarize.reduce"
    case replyOptions = "reply.options"
    case rewrite = "rewrite.instruct"
    case composeWrite = "compose.write"
    case classify = "triage.classify"
    case askInbox = "ask.inbox"
    case searchPlan = "search.plan"
    case searchTool = "search.tool"
    case autoLabel = "autolabel.classify"
    case followUp = "followup.detect"
    case schedulingExtract = "schedule.extract"
    case schedulingReply = "schedule.reply"
    case summarizeLine = "summarize.line"
    case composerImprove = "composer.improve"
    case composerShorter = "composer.shorter"
    case composerLonger = "composer.longer"
    case composerClearer = "composer.clearer"
    case composerFriendlier = "composer.friendlier"
    case composerDirect = "composer.direct"
    case composerSpelling = "composer.spelling"
    case composerTranslate = "composer.translate"
    case composerVoice = "composer.voice"
    case composerNotes = "composer.notes"
    case schedulingBookingLink = "schedule.booking-link"
    case schedulingOffer = "schedule.ask.offer"
    case schedulingBusy = "schedule.ask.busy"
    case schedulingAccept = "schedule.ask.accept"
    case schedulingAcceptMove = "schedule.ask.accept-move"
    case schedulingOtherTimes = "schedule.ask.other-times"
    case schedulingTimes = "schedule.times"

    public var task: AITask {
        switch self {
        case .summarizeThread, .summarizeLine: return .summarize
        case .summarizeChunk: return .summarizeChunk
        case .summarizeReduce: return .reduce
        case .replyOptions: return .replyOptions
        case .rewrite, .composeWrite: return .rewrite
        case .classify: return .classify
        case .askInbox: return .askInbox
        case .searchPlan, .searchTool: return .searchPlan
        case .autoLabel: return .classify
        case .followUp: return .followUp
        case .schedulingExtract, .schedulingReply: return .scheduling
        case .composerImprove, .composerShorter, .composerLonger, .composerClearer, .composerFriendlier,
             .composerDirect, .composerSpelling, .composerTranslate, .composerVoice, .composerNotes:
            return .rewrite
        case .schedulingBookingLink, .schedulingOffer, .schedulingBusy, .schedulingAccept, .schedulingAcceptMove,
             .schedulingOtherTimes, .schedulingTimes:
            return .scheduling
        }
    }

    public var role: PromptRole {
        switch self {
        case .composerImprove, .composerShorter, .composerLonger, .composerClearer, .composerFriendlier,
             .composerDirect, .composerSpelling, .composerTranslate, .composerVoice, .composerNotes,
             .schedulingBookingLink, .schedulingOffer, .schedulingBusy, .schedulingAccept, .schedulingAcceptMove,
             .schedulingOtherTimes, .schedulingTimes:
            return .instruction
        default:
            return .system
        }
    }

    public static var systemPrompts: [PromptName] { allCases.filter { $0.role == .system } }

    public static var instructionPrompts: [PromptName] { allCases.filter { $0.role == .instruction } }
}

public enum PromptRole: String, Sendable, Hashable {
    case system
    case instruction
    case shared
}

public struct PromptTemplate: Sendable, Hashable {
    public let id: PromptID
    public let body: String
    public internal(set) var override: PromptOverride?

    public init(fileContents: String) throws {
        let lines = fileContents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw PromptLibrary.LoadError.malformed("missing front matter")
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["id"], let versionText = fields["version"], let version = Int(versionText), version > 0
        else { throw PromptLibrary.LoadError.malformed("id/version") }
        id = PromptID(name, version: version)
        body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(id: PromptID, body: String) {
        self.id = id
        self.body = body
    }

    public var placeholders: Set<String> { PromptLibrary.placeholders(in: body) }

    public var identity: String { PromptOverride.identity(id, override) }
}

public struct RenderedPrompt: Sendable, Hashable {
    public let id: PromptID
    public let text: String
    public let digest: String
    public var overrideRevision: Int? = nil
    public var overrideDigest: String? = nil
    public var preambleOverridden = false
}

public struct PromptLibrary: Sendable {
    public enum LoadError: Error, Sendable, Equatable {
        case missing(String)
        case malformed(String)
        case unknownPlaceholder(String)
    }

    public static let preambleName = "common.preamble"
    public static let repairName = "common.repair"
    public static let languageMatchName = "common.language.match"
    public static let languageFixedName = "common.language.fixed"
    public static let sharedNames = [preambleName, repairName, languageMatchName, languageFixedName]

    public let templates: [String: PromptTemplate]

    public static let standard: PromptLibrary = (try? loadBundled()) ?? PromptLibrary(templates: [:])

    public init(templates: [String: PromptTemplate]) { self.templates = templates }

    public init(files: [String: String]) throws {
        var templates: [String: PromptTemplate] = [:]
        for contents in files.values {
            let template = try PromptTemplate(fileContents: contents)
            templates[template.id.name] = template
        }
        self.init(templates: templates)
    }

    public static func loadBundled() throws -> PromptLibrary {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: "Prompts"), !urls.isEmpty
        else { throw LoadError.missing("Prompts") }
        var files: [String: String] = [:]
        for url in urls { files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8) }
        return try PromptLibrary(files: files)
    }

    public func template(named name: String) throws -> PromptTemplate {
        guard let template = templates[name] else { throw LoadError.missing(name) }
        return template
    }

    public func system(_ name: PromptName, values: [String: String]) throws -> RenderedPrompt {
        let preamble = try template(named: Self.preambleName)
        let task = try template(named: name.rawValue)
        let raw = preamble.body + "\n\n" + task.body
        var rendered = RenderedPrompt(id: task.id, text: try Self.fill(raw, values: values), digest: try digest(name))
        rendered.overrideRevision = task.override?.revision
        rendered.overrideDigest = task.override?.digest
        rendered.preambleOverridden = preamble.override != nil
        return rendered
    }

    public func instruction(_ name: PromptName, values: [String: String] = [:]) throws -> String {
        try Self.fill(try template(named: name.rawValue).body, values: values)
    }

    public func overriding(_ overrides: [String: PromptOverride]) -> PromptLibrary {
        guard !overrides.isEmpty else { return self }
        var templates = self.templates
        for (name, override) in overrides {
            guard let bundled = templates[name] else { continue }
            var template = PromptTemplate(id: bundled.id, body: override.body)
            template.override = override
            templates[name] = template
        }
        return PromptLibrary(templates: templates)
    }

    public func languageRule(_ language: OutputLanguage) -> String {
        let match = (try? template(named: Self.languageMatchName).body) ?? ""
        switch language {
        case .matchEmail:
            return match
        case .fixed(let name):
            let cleaned = String(name.filter { $0.isLetter || $0 == " " || $0 == "-" }.prefix(40))
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, let fixed = try? template(named: Self.languageFixedName).body,
                  let filled = try? Self.fill(fixed, values: ["language": cleaned]) else { return match }
            return filled
        }
    }

    public func digest(_ name: PromptName) throws -> String {
        let preamble = try template(named: Self.preambleName)
        let task = try template(named: name.rawValue)
        return Digest.sha256Hex([preamble.id.description, preamble.body, task.id.description, task.body])
    }

    public func repairSuffix(schema: JSONSchema) throws -> String {
        try Self.fill(try template(named: Self.repairName).body, values: ["schema": schema.jsonString])
    }

    public static func fill(_ text: String, values: [String: String]) throws -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw LoadError.malformed("unclosed placeholder")
            }
            let name = String(rest[open.upperBound..<close.lowerBound])
            guard let value = values[name] else { throw LoadError.unknownPlaceholder(name) }
            out += value
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    static func placeholders(in text: String) -> Set<String> {
        var names = Set<String>()
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            names.insert(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return names
    }

    public static func languageRule(_ language: OutputLanguage) -> String {
        PromptLibraryProvider.shared.current.languageRule(language)
    }
}
