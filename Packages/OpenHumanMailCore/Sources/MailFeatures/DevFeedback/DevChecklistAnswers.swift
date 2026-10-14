import Foundation

public enum DevChecklistResult: String, Codable, Sendable, Hashable, CaseIterable {
    case worked
    case didNotWork
    case skipped

    public var title: String {
        switch self {
        case .worked: "Worked"
        case .didNotWork: "Didn't work"
        case .skipped: "Skip"
        }
    }
}

public struct DevChecklistAnswer: Codable, Sendable, Hashable {
    public var itemID: String
    public var result: DevChecklistResult?
    public var note: String
    public var answeredAt: Date
    public var exportedAt: Date?

    public init(itemID: String, result: DevChecklistResult?, note: String = "", answeredAt: Date, exportedAt: Date? = nil) {
        self.itemID = itemID
        self.result = result
        self.note = note
        self.answeredAt = answeredAt
        self.exportedAt = exportedAt
    }

    public var needsExport: Bool { exportedAt.map { $0 < answeredAt } ?? true }
}

public struct DevChecklistAnswerStore: Sendable {
    public static let format = "openhuman-dev-checklist-answers"
    public static let maxFileBytes = 2 * 1024 * 1024
    public static let maxNote = 4_000

    public let url: URL

    public init(url: URL) { self.url = url }

    private struct File: Codable {
        var format: String
        var formatVersion: Int
        var answers: [DevChecklistAnswer]
    }

    public func load() -> [String: DevChecklistAnswer] {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxFileBytes,
              let file = try? Self.decoder.decode(File.self, from: data), file.format == Self.format
        else { return [:] }
        var answers: [String: DevChecklistAnswer] = [:]
        for answer in file.answers where DevChecklistLoader.isValidID(answer.itemID) {
            var answer = answer
            answer.note = String(answer.note.prefix(Self.maxNote))
            answers[answer.itemID] = answer
        }
        return answers
    }

    public func save(_ answers: [String: DevChecklistAnswer]) throws {
        let file = File(format: Self.format, formatVersion: 1,
                        answers: answers.values.sorted { $0.itemID < $1.itemID })
        let data = try Self.encoder.encode(file)
        try DevFeedbackFiles.writePrivate(data, to: url)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum DevFeedbackFiles {
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
