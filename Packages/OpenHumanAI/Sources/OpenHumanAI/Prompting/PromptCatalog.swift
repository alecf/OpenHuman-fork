import Foundation

public struct PromptInfo: Sendable, Hashable, Identifiable {
    public enum Group: String, Sendable, Hashable, CaseIterable {
        case summaries, replies, composer, sorting, search, scheduling, followUps, shared
    }

    public enum ThreadTest: String, Sendable, Hashable {
        case summary, line, replies, triage, autoLabel
    }

    public let id: String
    public let title: String
    public let group: Group
    public let usedBy: String
    public let role: PromptRole
    public let slots: Set<String>
    public let neededSlots: Set<String>
    public let answersInJSON: Bool
    public let threadTest: ThreadTest?

    public var promptName: PromptName? { PromptName(rawValue: id) }
}

public enum PromptCatalog {
    public static let maxBodyBytes = 256 * 1024

    static let systemSlots: Set<String> = ["nonce", "languageRule"]
    static let schedulingSlots: Set<String> = ["name", "proposed"]

    public static let entries: [PromptInfo] = [
        info("summarize.thread", "Conversation summary", .summaries, "The summary at the top of a conversation",
             test: .summary),
        info("summarize.chunk", "Long conversation: one part", .summaries,
             "Summaries of conversations too long to read at once (each part)", test: .summary),
        info("summarize.reduce", "Long conversation: combined", .summaries,
             "Summaries of conversations too long to read at once (the parts combined)", test: .summary),
        info("summarize.line", "One-line summary", .summaries, "The line under each conversation's subject",
             test: .line),
        info("reply.options", "Quick replies", .replies, "Suggested replies under a message and in ⌘J", json: true,
             test: .replies),
        info("rewrite.instruct", "Rewrite (⌘J)", .replies, "⌘J over a draft or a selection in the composer"),
        info("compose.write", "Write from notes (⌘J)", .replies,
             "⌘J in an empty message: writes the email or reply from your notes"),
        info("composer.improve", "Preset: Improve writing", .composer, "The ⌘J chip “Improve writing”", role: .instruction),
        info("composer.shorter", "Preset: Shorten", .composer, "The ⌘J chip “Shorten”", role: .instruction),
        info("composer.longer", "Preset: Lengthen", .composer, "The ⌘J chip “Lengthen”", role: .instruction),
        info("composer.clearer", "Preset: Simplify", .composer, "The ⌘J chip “Simplify”", role: .instruction),
        info("composer.friendlier", "Preset: Friendlier", .composer, "The ⌘J chip “Friendlier”", role: .instruction),
        info("composer.direct", "Preset: More direct", .composer, "The ⌘J chip “More direct”", role: .instruction),
        info("composer.spelling", "Preset: Fix spelling", .composer, "The ⌘J chip “Fix spelling”", role: .instruction),
        info("composer.translate", "Preset: Translate", .composer,
             "The ⌘J chip “Translate…” (you finish the words in the field)", role: .instruction),
        info("composer.voice", "Preset: In my voice", .composer, "The ⌘J chip “In my voice”", role: .instruction),
        info("composer.notes", "Write from notes", .composer, "⌘J over an empty message: your notes go in {{notes}}",
             role: .instruction, slots: ["notes"], needed: ["notes"]),
        info("autolabel.classify", "Auto labels", .sorting, "The Respond, Meeting, News… labels on conversations",
             json: true, test: .autoLabel),
        info("triage.classify", "Triage", .sorting, "Sorting conversations by what they need from you", json: true,
             test: .triage),
        info("search.plan", "Search request", .search, "Searches you type in your own words", json: true),
        info("search.tool", "Search with the model", .search, "Ask AI searching your mail on this Mac"),
        info("ask.inbox", "Ask AI", .search, "Answers about your mail"),
        info("schedule.extract", "Proposed times", .scheduling, "Reading the times a message proposes", json: true),
        info("schedule.reply", "Scheduling reply", .scheduling, "Replies that offer, accept or ask for times"),
        info("schedule.booking-link", "Booking link line", .scheduling,
             "How your booking link is handed to a scheduling reply: the link goes in {{link}}", role: .instruction,
             slots: ["link"], needed: ["link"]),
        info("schedule.ask.offer", "Scheduling: offer other times", .scheduling,
             "The request behind a reply that offers other times: their name in {{name}}, their time in {{proposed}}",
             role: .instruction, slots: schedulingSlots),
        info("schedule.ask.busy", "Scheduling: busy then", .scheduling,
             "The request behind a reply when you're busy at their time", role: .instruction, slots: schedulingSlots),
        info("schedule.ask.accept", "Scheduling: accept", .scheduling, "The request behind a reply that accepts their time",
             role: .instruction, slots: schedulingSlots),
        info("schedule.ask.accept-move", "Scheduling: accept and move", .scheduling,
             "The request behind “Accept and move”", role: .instruction, slots: schedulingSlots),
        info("schedule.ask.other-times", "Scheduling: ask for other times", .scheduling,
             "The request behind a reply that asks them for other times", role: .instruction, slots: schedulingSlots),
        info("schedule.times", "Scheduling: the time lines", .scheduling,
             "How the exact times are handed to a scheduling reply: the lines go in {{times}}", role: .instruction,
             slots: ["times"], needed: ["times"]),
        info("followup.detect", "Follow-up check", .followUps, "Reminders for messages you sent that need an answer",
             json: true),
        info(PromptLibrary.preambleName, "Rules for every prompt", .shared,
             "Comes before every prompt above: how email text is fenced off", role: .shared, slots: systemSlots,
             needed: ["nonce"], test: .line),
        info(PromptLibrary.languageMatchName, "Language: same as the emails", .shared,
             "{{languageRule}} when the answer follows the emails' language", role: .shared, slots: [], test: .line),
        info(PromptLibrary.languageFixedName, "Language: a chosen language", .shared,
             "{{languageRule}} when Settings names a language: the name goes in {{language}}", role: .shared,
             slots: ["language"], needed: ["language"]),
        info(PromptLibrary.repairName, "Fix an invalid answer", .shared,
             "Added when an answer was not valid JSON: the expected form goes in {{schema}}", role: .shared,
             slots: ["schema"], needed: ["schema"]),
    ]

    private static func info(_ id: String, _ title: String, _ group: PromptInfo.Group, _ usedBy: String,
                             role: PromptRole = .system, slots: Set<String>? = nil, needed: Set<String> = [],
                             json: Bool = false, test: PromptInfo.ThreadTest? = nil) -> PromptInfo {
        PromptInfo(id: id, title: title, group: group, usedBy: usedBy, role: role,
                   slots: slots ?? (role == .system ? systemSlots : []), neededSlots: needed, answersInJSON: json,
                   threadTest: test)
    }

    public static func entry(_ id: String) -> PromptInfo? { entries.first { $0.id == id } }

    public static var ids: [String] { entries.map(\.id) }
}

public enum PromptProblem: Equatable, Sendable, Hashable {
    case empty
    case tooLarge(bytes: Int)
    case unknownSlot(String)
    case unclosedSlot
}

public enum PromptWarning: Equatable, Sendable, Hashable {
    case noJSONForm
    case injectionPolicy
    case missingSlot(String)
}

public struct PromptCheck: Equatable, Sendable {
    public var problems: [PromptProblem] = []
    public var warnings: [PromptWarning] = []
    public var canSave: Bool { problems.isEmpty }

    public init(problems: [PromptProblem] = [], warnings: [PromptWarning] = []) {
        self.problems = problems
        self.warnings = warnings
    }

    public static func of(_ body: String, for info: PromptInfo) -> PromptCheck {
        var check = PromptCheck()
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { check.problems.append(.empty) }
        let bytes = body.utf8.count
        if bytes > PromptCatalog.maxBodyBytes { check.problems.append(.tooLarge(bytes: bytes)) }
        if hasUnclosedSlot(body) { check.problems.append(.unclosedSlot) }
        let used = PromptLibrary.placeholders(in: body)
        for slot in used.subtracting(info.slots).sorted() { check.problems.append(.unknownSlot(slot)) }
        if info.answersInJSON, !body.contains("{\"") { check.warnings.append(.noJSONForm) }
        if info.id == PromptLibrary.preambleName { check.warnings.append(.injectionPolicy) }
        for slot in info.neededSlots.subtracting(used).sorted() { check.warnings.append(.missingSlot(slot)) }
        return check
    }

    static func hasUnclosedSlot(_ text: String) -> Bool {
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { return true }
            rest = rest[close.upperBound...]
        }
        return false
    }
}

public enum PromptDiff {
    public struct Line: Equatable, Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case same, added, removed }
        public let kind: Kind
        public let text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public static func lines(from old: String, to new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        guard a.count * b.count <= 4_000_000 else {
            return a.map { Line(.removed, $0) } + b.map { Line(.added, $0) }
        }
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                out.append(Line(.same, a[i]))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                out.append(Line(.removed, a[i]))
                i += 1
            } else {
                out.append(Line(.added, b[j]))
                j += 1
            }
        }
        out += a[i...].map { Line(.removed, $0) }
        out += b[j...].map { Line(.added, $0) }
        return out
    }
}
