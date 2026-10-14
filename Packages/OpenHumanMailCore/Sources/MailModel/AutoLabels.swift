import Foundation
import OpenHumanCore

extension AppSettings {
    public static let autoLabelsEnabled = AppSettingKey(name: "inbox.auto_labels.enabled", defaultValue: true)
    public static let autoLabelsApplyToGmail = AppSettingKey(name: "inbox.auto_labels.apply_to_gmail", defaultValue: true)
    public static let autoLabelsShowInGmail = AppSettingKey(name: "inbox.auto_labels.show_in_gmail", defaultValue: true)
    public static let autoLabelsSince = AppSettingKey(name: "inbox.auto_labels.since", defaultValue: 0.0)
}

public enum AutoLabelSource: String, Sendable, Hashable, Codable {
    case model
    case gmailLabel
    case derived
    case user
}

public struct AutoLabelEntry: Sendable, Hashable, Codable {
    public var account: AccountID
    public var thread: GmailThreadID
    public var latestMessage: GmailMessageID
    public var promptVersion: Int
    public var modelID: String
    public var category: String?
    public var source: AutoLabelSource
    public var classifiedAt: Date
    public var rejected: [String]
    public var writtenToGmail: Bool
    public var modelOutput: String?
    public var ruleID: String?
    public var ruleSetVersion: Int?

    public init(account: AccountID, thread: GmailThreadID, latestMessage: GmailMessageID, promptVersion: Int,
                modelID: String, category: String?, source: AutoLabelSource, classifiedAt: Date,
                rejected: [String] = [], writtenToGmail: Bool = false, modelOutput: String? = nil,
                ruleID: String? = nil, ruleSetVersion: Int? = nil) {
        self.account = account
        self.thread = thread
        self.latestMessage = latestMessage
        self.promptVersion = promptVersion
        self.modelID = modelID
        self.category = category.flatMap(OHGmailLabels.canonicalAutoLabelCategory)
        self.source = source
        self.classifiedAt = classifiedAt
        self.rejected = Array(Set(rejected.compactMap(OHGmailLabels.canonicalAutoLabelCategory))).sorted()
        self.writtenToGmail = writtenToGmail
        self.modelOutput = modelOutput
        self.ruleID = ruleID
        self.ruleSetVersion = ruleSetVersion
    }

    public func rejects(_ category: String?) -> Bool {
        guard let category = category.flatMap(OHGmailLabels.canonicalAutoLabelCategory) else { return false }
        return rejected.contains(category)
    }

    public func isCurrent(latest: GmailMessageID, promptVersion: Int, modelID: String) -> Bool {
        guard latestMessage == latest else { return false }
        guard source == .model else { return true }
        return self.promptVersion == promptVersion && self.modelID == modelID
    }
}

public enum AutoLabelRejections {
    public static func encode(_ rejected: [String]) -> String? {
        rejected.isEmpty ? nil : rejected.joined(separator: ",")
    }

    public static func decode(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").compactMap { OHGmailLabels.canonicalAutoLabelCategory(String($0)) }
    }
}

public protocol AutoLabelStoring: Sendable {
    func entries(account: AccountID) async throws -> [AutoLabelEntry]
    func entry(account: AccountID, thread: GmailThreadID) async throws -> AutoLabelEntry?
    func put(_ entries: [AutoLabelEntry]) async throws
    func accountIDs() async throws -> [AccountID]
    func removeAll(account: AccountID) async throws
    func removeAll() async throws
}

public actor InMemoryAutoLabelStore: AutoLabelStoring, DecisionLogStoring {
    private var rows: [AccountID: [GmailThreadID: AutoLabelEntry]] = [:]
    private var log: [ClassificationDecision] = []
    private var nextDecisionID: Int64 = 1

    public init(_ entries: [AutoLabelEntry] = []) {
        for entry in entries { rows[entry.account, default: [:]][entry.thread] = entry }
    }

    public func entries(account: AccountID) async throws -> [AutoLabelEntry] {
        Array((rows[account] ?? [:]).values).sorted { $0.thread.rawValue < $1.thread.rawValue }
    }

    public func entry(account: AccountID, thread: GmailThreadID) async throws -> AutoLabelEntry? { rows[account]?[thread] }

    public func put(_ entries: [AutoLabelEntry]) async throws {
        for entry in entries { rows[entry.account, default: [:]][entry.thread] = entry }
    }

    public func accountIDs() async throws -> [AccountID] {
        rows.filter { !$0.value.isEmpty }.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func removeAll(account: AccountID) async throws { rows[account] = nil }

    public func removeAll() async throws { rows = [:] }

    public var count: Int { rows.values.reduce(0) { $0 + $1.count } }


    public func appendDecisions(_ new: [ClassificationDecision], now: Date, maxRows: Int, maxDays: Int) async throws {
        for var row in new {
            row.id = nextDecisionID
            nextDecisionID += 1
            log.append(row)
        }
        let cutoff = now.addingTimeInterval(-Double(maxDays) * 86_400)
        log.removeAll { $0.decidedAt < cutoff }
        if log.count > maxRows { log.removeFirst(log.count - max(0, maxRows)) }
    }

    public func decisions(limit: Int) async throws -> [ClassificationDecision] {
        Array(log.sorted { ($0.decidedAt, $0.id) > ($1.decidedAt, $1.id) }.prefix(max(0, limit)))
    }

    public func latestDecision(account: AccountID, thread: GmailThreadID) async throws -> ClassificationDecision? {
        log.filter { $0.account == account && $0.thread == thread }.max { ($0.decidedAt, $0.id) < ($1.decidedAt, $1.id) }
    }

    public func setApplied(account: AccountID, thread: GmailThreadID, latestMessage: GmailMessageID,
                           state: DecisionAppliedState, label: String?) async throws {
        guard let index = log.lastIndex(where: { $0.account == account && $0.thread == thread
            && $0.latestMessage == latestMessage }) else { return }
        log[index].appliedState = state
        log[index].appliedLabel = label
    }

    public func removeAllDecisions() async throws { log = [] }

    public func decisionCount() async throws -> Int { log.count }
}

public enum AutoLabelRule {
    public static let matcherID = "category"

    public static func value(for category: String) -> String? {
        OHGmailLabels.canonicalAutoLabelCategory(category).map { matcherID + ":" + $0.lowercased() }
    }

    public static func category(inValue value: String) -> String? {
        guard let colon = value.firstIndex(of: ":"),
              value[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == matcherID else { return nil }
        return OHGmailLabels.canonicalAutoLabelCategory(String(value[value.index(after: colon)...]))
    }
}
