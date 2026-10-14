import Foundation
import MailModel

public struct FeedbackThreadHeader: Sendable, Hashable {
    public var subject: String
    public var senderName: String

    public init(subject: String, senderName: String) {
        self.subject = subject
        self.senderName = senderName
    }
}

public struct FeedbackAttachment: Sendable, Hashable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

@MainActor
public protocol FeedbackContributor: AnyObject {
    var id: String { get }
    var title: String { get }
    var isOnByDefault: Bool { get }
    var containsEmailContent: Bool { get }
    func attachments() async -> [FeedbackAttachment]
}

public struct FeedbackManifest: Codable, Sendable, Equatable {
    public struct Includes: Codable, Sendable, Equatable {
        public var note: Bool
        public var diagnostics: Bool
        public var screenshot: Bool
        public var threadSubjectAndSender: Bool
        public var extras: [String]
    }

    public var format = "openhuman-feedback"
    public var formatVersion = 1
    public var createdAt: Date
    public var appVersion: String
    public var build: String
    public var commit: String
    public var macOS: String
    public var accountCount: Int
    public var includes: Includes
}

public struct FeedbackInput: Sendable {
    public var note: String
    public var app: DiagnosticsAppInfo
    public var accountCount: Int
    public var diagnostics: [String: Data]?
    public var screenshotPNG: Data?
    public var thread: FeedbackThreadHeader?
    public var extras: [String: [FeedbackAttachment]]
    public var now: Date

    public init(note: String, app: DiagnosticsAppInfo, accountCount: Int, diagnostics: [String: Data]? = nil,
                screenshotPNG: Data? = nil, thread: FeedbackThreadHeader? = nil,
                extras: [String: [FeedbackAttachment]] = [:], now: Date) {
        self.note = note
        self.app = app
        self.accountCount = accountCount
        self.diagnostics = diagnostics
        self.screenshotPNG = screenshotPNG
        self.thread = thread
        self.extras = extras
        self.now = now
    }
}

public struct FeedbackBundle: Sendable {
    public let fileName: String
    public let data: Data
    public let manifest: FeedbackManifest
}

public enum FeedbackBundler {
    public static let maxNoteLength = 20_000

    public static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0,
                      c.second ?? 0)
    }

    public static func fileName(for date: Date) -> String { "OpenHuman-feedback-\(stamp(date)).zip" }

    public static func build(_ input: FeedbackInput) throws -> FeedbackBundle {
        let folder = "OpenHuman-feedback-\(stamp(input.now))"
        var zip = ZipArchive()
        func add(_ name: String, _ data: Data) { zip.add(name: "\(folder)/\(name)", data: data, modified: input.now) }

        let note = String(input.note.prefix(maxNoteLength))
        add("note.txt", Data((note.isEmpty ? "(no note)\n" : note + "\n").utf8))

        let redactor = DevFeedbackRedactor()
        if let diagnostics = input.diagnostics {
            for (name, data) in diagnostics.sorted(by: { $0.key < $1.key }) {
                let safe = safeFileName(name)
                if safe.hasSuffix(".txt") {
                    let text = String(decoding: data, as: UTF8.self)
                    let scrubbed = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { redactor.scrub(String($0)) }.joined(separator: "\n")
                    add("diagnostics/\(safe)", Data(scrubbed.utf8))
                } else {
                    add("diagnostics/\(safe)", data)
                }
            }
        }
        if let png = input.screenshotPNG { add("screenshot.png", png) }
        if let thread = input.thread {
            add("thread.txt", Data("Contains email content (you ticked the box).\nSubject: \(thread.subject)\nSender: \(thread.senderName)\n".utf8))
        }
        var extraIDs: [String] = []
        for (id, files) in input.extras.sorted(by: { $0.key < $1.key }) {
            let folderName = safeFileName(id)
            extraIDs.append(folderName)
            for file in files { add("extra/\(folderName)/\(safeFileName(file.name))", file.data) }
        }

        let manifest = FeedbackManifest(
            createdAt: input.now, appVersion: matching(input.app.version, Self.versionPattern),
            build: matching(input.app.build, Self.versionPattern), commit: matching(input.app.gitCommit, Self.commitPattern),
            macOS: matching(input.app.os, Self.osPattern), accountCount: max(0, input.accountCount),
            includes: .init(note: !note.isEmpty, diagnostics: input.diagnostics != nil, screenshot: input.screenshotPNG != nil,
                            threadSubjectAndSender: input.thread != nil, extras: extraIDs.sorted()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        add("manifest.json", try encoder.encode(manifest))
        return FeedbackBundle(fileName: fileName(for: input.now), data: zip.data(), manifest: manifest)
    }

    static let versionPattern = #"^[0-9]{1,9}(\.[0-9]{1,9}){0,3}([-+][0-9A-Za-z.]{1,16})?$"#
    static let commitPattern = #"^([0-9a-f]{7,40}(-dirty)?|unknown)$"#
    static let osPattern = #"^Version [0-9]{1,3}(\.[0-9]{1,3}){0,2}( \(Build [0-9A-Za-z]{1,12}\))?$"#

    static func matching(_ value: String, _ pattern: String) -> String {
        value.count <= 64 && value.range(of: pattern, options: .regularExpression) != nil ? value : "<redacted>"
    }

    static func safeFileName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." || $0 == "-"
        }))
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(64))
        return cleaned.isEmpty ? "file" : cleaned
    }
}
