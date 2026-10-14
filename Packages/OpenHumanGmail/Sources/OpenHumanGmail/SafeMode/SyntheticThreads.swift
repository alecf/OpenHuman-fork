import Foundation
import OpenHumanCore

public struct SyntheticThreads: Sendable {
    public static let senderName = "OpenHuman Test"
    public static let senderAddress = "test@openhuman.invalid"
    public static let subjectPrefix = "[OpenHuman test]"
    public static let messageIDDomain = "openhuman.invalid"
    public static let runHeader = "X-OpenHuman-Test-Run"

    public struct Inserted: Sendable, Hashable, Codable {
        public var index: Int
        public var messageID: String
        public var threadID: String
        public var rfc822MessageID: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidRunID
        case invalidCount
        case missingIDs
    }

    public let api: any GmailAPI
    public let runID: String

    public init(api: any GmailAPI, runID: String) throws {
        guard Self.isValidRunID(runID) else { throw Failure.invalidRunID }
        self.api = api
        self.runID = runID
    }

    public static func makeRunID(now: Date = Date()) -> String {
        ScheduleStamp.format(now) + "-" + String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }

    static func isValidRunID(_ value: String) -> Bool {
        guard (1...40).contains(value.utf8.count), value.first != "-" else { return false }
        return value.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
        }
    }

    public func ensureTestLabel() async throws -> String {
        if let id = try await api.listLabels().first(where: { $0.name == OHGmailLabels.test })?.id { return id }
        do {
            return try await api.createLabel(name: OHGmailLabels.test, labelListVisibility: "labelShow",
                                             messageListVisibility: "show").id
        } catch GmailError.badRequest(reason: "conflict", _) {
            guard let id = try await api.listLabels().first(where: { $0.name == OHGmailLabels.test })?.id else {
                throw GmailError.notFound("labels/\(OHGmailLabels.test)")
            }
            return id
        }
    }

    public func insertThreads(count: Int, firstIndex: Int = 1, inbox: Bool = true, unread: Bool = true,
                              date: Date = Date()) async throws -> [Inserted] {
        guard count >= 1, count <= 500, firstIndex >= 0 else { throw Failure.invalidCount }
        let labels = try await labelIDs(inbox: inbox, unread: unread)
        var out: [Inserted] = []
        for index in firstIndex..<(firstIndex + count) {
            out.append(try await insert(index: index, subjectIndex: index, inReplyTo: nil, labels: labels, date: date))
        }
        Log(.gmail).notice("synthetic threads inserted: \(out.count) (run \(runID))")
        return out
    }

    public func insertReply(to parent: Inserted, index: Int, unread: Bool = true,
                            date: Date = Date()) async throws -> Inserted {
        guard index >= 0 else { throw Failure.invalidCount }
        let labels = try await labelIDs(inbox: true, unread: unread)
        return try await insert(index: index, subjectIndex: parent.index, inReplyTo: parent.rfc822MessageID,
                                labels: labels, date: date)
    }

    public func cleanUp(_ inserted: [Inserted]) async throws {
        let ids = inserted.map(\.messageID)
        for chunk in stride(from: 0, to: ids.count, by: 1000).map({ Array(ids[$0..<min($0 + 1000, ids.count)]) }) {
            try await api.batchModifyMessages(ids: chunk, add: [], remove: ["INBOX"])
        }
        var seen = Set<String>()
        for thread in inserted.map(\.threadID) where seen.insert(thread).inserted {
            _ = try await api.trashThread(id: thread)
        }
        Log(.gmail).notice("synthetic threads cleaned up: \(seen.count) trashed (run \(runID))")
    }

    public static func rfc822MessageID(runID: String, index: Int) -> String {
        "<oh-test.\(runID).\(index)@\(messageIDDomain)>"
    }

    public static func subject(runID: String, index: Int) -> String { "\(subjectPrefix) \(runID) \(index)" }

    public static func message(runID: String, index: Int, subjectIndex: Int? = nil, to: String, date: Date,
                               inReplyTo: String? = nil) -> Data {
        var lines = [
            "From: \(senderName) <\(senderAddress)>",
            "To: \(to)",
            "Subject: \(subject(runID: runID, index: subjectIndex ?? index))",
            "Date: \(rfc5322(date))",
            "Message-ID: \(rfc822MessageID(runID: runID, index: index))",
        ]
        if let inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
            lines.append("References: \(inReplyTo)")
        }
        lines += [
            "\(runHeader): \(runID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Synthetic test message \(index) of run \(runID). It contains no real content.",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func labelIDs(inbox: Bool, unread: Bool) async throws -> [String] {
        var labels = [try await ensureTestLabel()]
        if inbox { labels.append("INBOX") }
        if unread { labels.append("UNREAD") }
        return labels
    }

    private func insert(index: Int, subjectIndex: Int, inReplyTo: String?, labels: [String],
                        date: Date) async throws -> Inserted {
        let raw = Self.message(runID: runID, index: index, subjectIndex: subjectIndex, to: api.accountEmail, date: date,
                               inReplyTo: inReplyTo)
        let message = try await api.insertMessage(rawRFC822: raw, labelIDs: labels)
        guard !message.id.isEmpty, let thread = message.threadId, !thread.isEmpty else { throw Failure.missingIDs }
        return Inserted(index: index, messageID: message.id, threadID: thread,
                        rfc822MessageID: Self.rfc822MessageID(runID: runID, index: index))
    }

    static func rfc5322(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
