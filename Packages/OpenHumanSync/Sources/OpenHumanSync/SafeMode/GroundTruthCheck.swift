import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public struct GroundTruthReport: Codable, Sendable, Hashable {
    public struct CountMismatch: Codable, Sendable, Hashable {
        public var labelID: String
        public var field: String
        public var gmail: Int?
        public var store: Int?

        public init(labelID: String, field: String, gmail: Int? = nil, store: Int? = nil) {
            self.labelID = labelID
            self.field = field
            self.gmail = gmail
            self.store = store
        }
    }

    public struct ThreadMismatch: Codable, Sendable, Hashable {
        public var threadID: String
        public var missingInStore: Bool
        public var messagesOnlyInGmail: [String]
        public var messagesOnlyInStore: [String]
        public var labelMismatches: [String]

        public init(threadID: String, missingInStore: Bool = false, messagesOnlyInGmail: [String] = [],
                    messagesOnlyInStore: [String] = [], labelMismatches: [String] = []) {
            self.threadID = threadID
            self.missingInStore = missingInStore
            self.messagesOnlyInGmail = messagesOnlyInGmail
            self.messagesOnlyInStore = messagesOnlyInStore
            self.labelMismatches = labelMismatches
        }
    }

    public var accountHash: String
    public var snapshotTakenAt: Date
    public var comparedAt: Date
    public var gmailCounts: [String: GroundTruthSnapshot.LabelCounts]
    public var labelsCompared: Int
    public var inboxThreadsCompared: Int
    public var countMismatches: [CountMismatch]
    public var inboxOnlyInGmail: [String]
    public var inboxOnlyInStore: [String]
    public var threadMismatches: [ThreadMismatch]

    public var isClean: Bool {
        countMismatches.isEmpty && inboxOnlyInGmail.isEmpty && inboxOnlyInStore.isEmpty && threadMismatches.isEmpty
    }
}

public enum GroundTruthCheck {
    public enum Failure: Error, Equatable, Sendable {
        case accountMismatch
    }

    public static func compare(store: any MailReading, account: AccountID, snapshot: GroundTruthSnapshot,
                               now: Date = Date()) throws -> GroundTruthReport {
        guard let item = try store.accounts().first(where: { $0.id == account }),
              WriteAllowlist.accountHash(item.email) == snapshot.accountHash else {
            throw Failure.accountMismatch
        }

        var countMismatches: [GroundTruthReport.CountMismatch] = []
        let labels = Dictionary(try store.labels(account: account).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, counts) in snapshot.labels.sorted(by: { $0.key < $1.key }) {
            guard let local = labels[id] else {
                countMismatches.append(.init(labelID: id, field: "label missing in store", gmail: counts.threadsTotal))
                continue
            }
            if let total = counts.threadsTotal, total != local.totalThreads {
                countMismatches.append(.init(labelID: id, field: "threadsTotal", gmail: total, store: local.totalThreads))
            }
            if let unread = counts.threadsUnread, unread != local.unreadThreads {
                countMismatches.append(.init(labelID: id, field: "threadsUnread", gmail: unread, store: local.unreadThreads))
            }
        }

        let n = snapshot.inboxThreadIDs.count
        let localInbox = n == 0 ? [] : try store.threadPage(view: .system(account, .inbox), after: nil, limit: n)
            .items.map(\.ref.gmailThreadID.rawValue)
        let gmailSet = Set(snapshot.inboxThreadIDs), localSet = Set(localInbox)

        var threadMismatches: [GroundTruthReport.ThreadMismatch] = []
        for threadID in snapshot.inboxThreadIDs {
            guard let facts = snapshot.threads[threadID] else { continue }
            guard let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(threadID)),
                  let detail = try store.threadDetail(ref.rowID) else {
                threadMismatches.append(.init(threadID: threadID, missingInStore: true,
                                              messagesOnlyInGmail: facts.messages.map(\.id)))
                continue
            }
            let local = Dictionary(detail.messages.map {
                ($0.gmailMessageID.rawValue, GroundTruth.labelHash($0.labelIDs.map(\.rawValue)))
            }, uniquingKeysWith: { a, _ in a })
            let remote = Dictionary(facts.messages.map { ($0.id, $0.labelHash) }, uniquingKeysWith: { a, _ in a })
            let onlyGmail = remote.keys.filter { local[$0] == nil }.sorted()
            let onlyStore = local.keys.filter { remote[$0] == nil }.sorted()
            let labelDiffs = remote.filter { id, hash in local[id].map { $0 != hash } ?? false }.keys.sorted()
            if !onlyGmail.isEmpty || !onlyStore.isEmpty || !labelDiffs.isEmpty {
                threadMismatches.append(.init(threadID: threadID, messagesOnlyInGmail: onlyGmail,
                                              messagesOnlyInStore: onlyStore, labelMismatches: labelDiffs))
            }
        }

        return GroundTruthReport(accountHash: snapshot.accountHash, snapshotTakenAt: snapshot.takenAt, comparedAt: now,
                                 gmailCounts: snapshot.labels, labelsCompared: snapshot.labels.count,
                                 inboxThreadsCompared: n, countMismatches: countMismatches,
                                 inboxOnlyInGmail: snapshot.inboxThreadIDs.filter { !localSet.contains($0) },
                                 inboxOnlyInStore: localInbox.filter { !gmailSet.contains($0) },
                                 threadMismatches: threadMismatches)
    }

    @discardableResult
    public static func write(_ report: GroundTruthReport, storeDirectory: URL) throws -> URL {
        let logs = storeDirectory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let file = logs.appendingPathComponent("ground-truth-\(formatter.string(from: report.comparedAt)).json")
        guard FileManager.default.createFile(atPath: file.path, contents: try encoder.encode(report),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        Log(.sync).notice("ground truth: \(report.countMismatches.count) count, \(report.inboxOnlyInGmail.count + report.inboxOnlyInStore.count) inbox and \(report.threadMismatches.count) thread mismatches")
        return file
    }
}
