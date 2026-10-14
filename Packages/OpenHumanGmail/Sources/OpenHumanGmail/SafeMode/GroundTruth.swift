import Crypto
import Foundation
import OpenHumanCore

public struct GroundTruthSnapshot: Codable, Sendable, Hashable {
    public struct LabelCounts: Codable, Sendable, Hashable {
        public var messagesTotal: Int?
        public var messagesUnread: Int?
        public var threadsTotal: Int?
        public var threadsUnread: Int?

        public init(messagesTotal: Int? = nil, messagesUnread: Int? = nil, threadsTotal: Int? = nil,
                    threadsUnread: Int? = nil) {
            self.messagesTotal = messagesTotal
            self.messagesUnread = messagesUnread
            self.threadsTotal = threadsTotal
            self.threadsUnread = threadsUnread
        }
    }

    public struct MessageFacts: Codable, Sendable, Hashable {
        public var id: String
        public var labelHash: String

        public init(id: String, labelHash: String) {
            self.id = id
            self.labelHash = labelHash
        }
    }

    public struct ThreadFacts: Codable, Sendable, Hashable {
        public var historyID: String?
        public var messages: [MessageFacts]

        public init(historyID: String? = nil, messages: [MessageFacts]) {
            self.historyID = historyID
            self.messages = messages
        }
    }

    public var accountHash: String
    public var takenAt: Date
    public var labels: [String: LabelCounts]
    public var inboxThreadIDs: [String]
    public var threads: [String: ThreadFacts]

    public init(accountHash: String, takenAt: Date, labels: [String: LabelCounts], inboxThreadIDs: [String],
                threads: [String: ThreadFacts]) {
        self.accountHash = accountHash
        self.takenAt = takenAt
        self.labels = labels
        self.inboxThreadIDs = inboxThreadIDs
        self.threads = threads
    }
}

public enum GroundTruth {
    public static let defaultLabels = ["INBOX", "UNREAD", "STARRED", "SENT", "DRAFT"]

    public static func labelHash(_ labelIDs: some Sequence<String>) -> String {
        SHA256.hash(data: Data(Set(labelIDs).sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func snapshot(api: any GmailAPI, labels: [String]? = nil, sampleThreads: Int = 200,
                                now: Date = Date()) async throws -> GroundTruthSnapshot {
        let labelIDs: [String]
        if let labels {
            labelIDs = labels
        } else {
            let user = try await api.listLabels().filter { $0.type == "user" }.map(\.id).sorted()
            labelIDs = defaultLabels + user
        }
        var counts: [String: GroundTruthSnapshot.LabelCounts] = [:]
        for id in labelIDs {
            let label = try await api.getLabel(id: id)
            counts[id] = .init(messagesTotal: label.messagesTotal, messagesUnread: label.messagesUnread,
                               threadsTotal: label.threadsTotal, threadsUnread: label.threadsUnread)
        }

        var inbox: [String] = []
        var pageToken: String?
        let wanted = max(0, sampleThreads)
        while inbox.count < wanted {
            let page = try await api.listThreads(ListQuery(labelIDs: ["INBOX"], pageToken: pageToken,
                                                           maxResults: min(500, wanted - inbox.count)),
                                                 priority: .sync)
            inbox += (page.threads ?? []).map(\.id)
            guard let next = page.nextPageToken, !(page.threads ?? []).isEmpty else { break }
            pageToken = next
        }
        inbox = Array(inbox.prefix(wanted))

        var threads: [String: GroundTruthSnapshot.ThreadFacts] = [:]
        for item in try await api.getThreads(ids: inbox, format: .minimal, metadataHeaders: [], priority: .sync) {
            let thread = try item.result.get()
            let messages = (thread.messages ?? [])
                .map { GroundTruthSnapshot.MessageFacts(id: $0.id, labelHash: labelHash($0.labelIds ?? [])) }
                .sorted { $0.id < $1.id }
            threads[item.id] = .init(historyID: thread.historyId, messages: messages)
        }
        return GroundTruthSnapshot(accountHash: WriteAllowlist.accountHash(api.accountEmail), takenAt: now,
                                   labels: counts, inboxThreadIDs: inbox, threads: threads)
    }
}
