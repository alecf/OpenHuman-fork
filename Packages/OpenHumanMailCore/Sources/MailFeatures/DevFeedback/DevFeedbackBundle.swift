import Foundation

public enum DevFeedbackCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case bug, confusing, idea, praise

    public var title: String {
        switch self {
        case .bug: "Bug"
        case .confusing: "Confusing"
        case .idea: "Idea"
        case .praise: "Praise"
        }
    }
}

public struct DevFeedbackBundle: Codable, Sendable, Hashable {
    public static let format = "openhuman-dev-feedback"

    public struct Attachments: Codable, Sendable, Hashable {
        public var snapshot: Bool
        public var logs: Bool
        public var threadSubjectAndSender: Bool
        public var screenshot: Bool
    }

    public struct ThreadContent: Codable, Sendable, Hashable {
        public var warning = "contains email content"
        public var threadID: String
        public var subject: String
        public var sender: String
    }

    public struct ChecklistAnswer: Codable, Sendable, Hashable {
        public var itemID: String
        public var area: String?
        public var title: String?
        public var result: String?
        public var note: String
        public var answeredAt: Date
    }

    public struct Checklist: Codable, Sendable, Hashable {
        public var source: String
        public var itemCount: Int
        public var testedCount: Int
        public var answers: [ChecklistAnswer]
    }

    public var format = DevFeedbackBundle.format
    public var formatVersion = 1
    public var id: String
    public var createdAt: Date
    public var category: DevFeedbackCategory
    public var text: String
    public var attachments: Attachments
    public var snapshot: DevFeedbackSnapshot?
    public var logs: [DevFeedbackLogBuffer.Line]?
    public var content: ThreadContent?
    public var screenshotFile: String?
    public var checklist: Checklist

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct DevFeedbackExport: Sendable, Hashable {
    public let bundleURL: URL
    public let screenshotURL: URL?

    public var files: [URL] { [bundleURL] + (screenshotURL.map { [$0] } ?? []) }
}

public enum DevFeedbackExporter {
    public static let maxTextLength = 20_000

    public static func baseName(createdAt: Date, id: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: createdAt)
        let stamp = String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                           c.minute ?? 0, c.second ?? 0)
        return "feedback-\(stamp)-\(id)"
    }

    public static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    public static func write(_ bundle: DevFeedbackBundle, screenshot: Data?, to directory: URL) throws -> DevFeedbackExport {
        var bundle = bundle
        let fm = FileManager.default
        var base = baseName(createdAt: bundle.createdAt, id: bundle.id)
        while fm.fileExists(atPath: directory.appendingPathComponent(base + ".json").path) {
            bundle.id = makeID()
            base = baseName(createdAt: bundle.createdAt, id: bundle.id)
        }
        var screenshotURL: URL?
        if let screenshot {
            let url = directory.appendingPathComponent(base + ".png")
            try DevFeedbackFiles.writePrivate(screenshot, to: url)
            screenshotURL = url
            bundle.screenshotFile = url.lastPathComponent
        }
        let url = directory.appendingPathComponent(base + ".json")
        try DevFeedbackFiles.writePrivate(try DevFeedbackBundle.encoder.encode(bundle), to: url)
        return DevFeedbackExport(bundleURL: url, screenshotURL: screenshotURL)
    }
}
