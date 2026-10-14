import Foundation
import OpenHumanCore

extension AppSettings {
    public static let classificationTeachFromCorrections = AppSettingKey(name: "classification.teach_from_corrections",
                                                                         defaultValue: true)
    public static let classificationSuggestRules = AppSettingKey(name: "classification.suggest_rules", defaultValue: true)
    public static let classificationDecisionLogEnabled = AppSettingKey(name: "classification.decision_log.enabled",
                                                                       defaultValue: true)
    public static let classificationDecisionLogMaxRows = AppSettingKey(name: "classification.decision_log.max_rows",
                                                                       defaultValue: 100_000)
    public static let classificationDecisionLogMaxDays = AppSettingKey(name: "classification.decision_log.max_days",
                                                                       defaultValue: 180)
    public static let classificationKeepInputText = AppSettingKey(name: "classification.keep_input_text", defaultValue: false)
    public static let classificationNotImportantRemovesGmailFlag = AppSettingKey(
        name: "classification.not_important.removes_gmail_flag", defaultValue: false)
    public static let classificationRulesHistoryLimit = AppSettingKey(name: "classification.rules.history_limit",
                                                                      defaultValue: 500)
    public static let classificationKeySalt = AppSettingKey(name: "classification.key_salt", defaultValue: "")
}


public enum DecisionAppliedState: String, Sendable, Hashable, Codable {
    case pending
    case written
    case localOnly = "local_only"
    case failed
}

public struct ClassificationDecision: Sendable, Hashable, Codable, Identifiable {
    public var id: Int64
    public var account: AccountID
    public var thread: GmailThreadID
    public var latestMessage: GmailMessageID
    public var decidedAt: Date
    public var feature: String
    public var decidedBy: String
    public var ruleID: String?
    public var ruleSetVersion: Int?
    public var promptID: String?
    public var promptVersion: Int?
    public var promptDigest: String?
    public var providerID: String?
    public var modelID: String?
    public var featuresJSON: String
    public var constraintsJSON: String?
    public var modelOutput: String?
    public var outputLabel: String?
    public var appliedLabel: String?
    public var appliedState: DecisionAppliedState
    public var textJSON: String?

    public init(id: Int64 = 0, account: AccountID, thread: GmailThreadID, latestMessage: GmailMessageID, decidedAt: Date,
                feature: String = "autolabel", decidedBy: String, ruleID: String? = nil, ruleSetVersion: Int? = nil,
                promptID: String? = nil, promptVersion: Int? = nil, promptDigest: String? = nil,
                providerID: String? = nil, modelID: String? = nil, featuresJSON: String = "{}",
                constraintsJSON: String? = nil, modelOutput: String? = nil, outputLabel: String? = nil,
                appliedLabel: String? = nil, appliedState: DecisionAppliedState = .pending, textJSON: String? = nil) {
        self.id = id
        self.account = account
        self.thread = thread
        self.latestMessage = latestMessage
        self.decidedAt = decidedAt
        self.feature = feature
        self.decidedBy = decidedBy
        self.ruleID = ruleID
        self.ruleSetVersion = ruleSetVersion
        self.promptID = promptID
        self.promptVersion = promptVersion
        self.promptDigest = promptDigest
        self.providerID = providerID
        self.modelID = modelID
        self.featuresJSON = featuresJSON
        self.constraintsJSON = constraintsJSON
        self.modelOutput = modelOutput
        self.outputLabel = outputLabel
        self.appliedLabel = appliedLabel
        self.appliedState = appliedState
        self.textJSON = textJSON
    }
}

public protocol DecisionLogStoring: Sendable {
    func appendDecisions(_ rows: [ClassificationDecision], now: Date, maxRows: Int, maxDays: Int) async throws
    func decisions(limit: Int) async throws -> [ClassificationDecision]
    func latestDecision(account: AccountID, thread: GmailThreadID) async throws -> ClassificationDecision?
    func setApplied(account: AccountID, thread: GmailThreadID, latestMessage: GmailMessageID,
                    state: DecisionAppliedState, label: String?) async throws
    func removeAllDecisions() async throws
    func decisionCount() async throws -> Int
}


public struct LabelledExample: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var account: AccountID?
    public var thread: GmailThreadID?
    public var latestMessage: GmailMessageID?
    public var createdAt: Date
    public var source: String
    public var feature: String
    public var expected: String
    public var rejected: [String]
    public var was: String?
    public var decisionID: Int64?
    public var ruleID: String?
    public var modelID: String?
    public var sender: String?
    public var senderDomain: String?
    public var listID: String?
    public var featuresJSON: String
    public var scope: String?
    public var createdRuleID: String?
    public var textJSON: String?

    public init(id: String = UUID().uuidString, account: AccountID? = nil, thread: GmailThreadID? = nil,
                latestMessage: GmailMessageID? = nil, createdAt: Date, source: String = "correction",
                feature: String = "autolabel", expected: String, rejected: [String] = [], was: String? = nil,
                decisionID: Int64? = nil, ruleID: String? = nil, modelID: String? = nil, sender: String? = nil,
                senderDomain: String? = nil, listID: String? = nil, featuresJSON: String = "{}", scope: String? = "thread",
                createdRuleID: String? = nil, textJSON: String? = nil) {
        self.id = id
        self.account = account
        self.thread = thread
        self.latestMessage = latestMessage
        self.createdAt = createdAt
        self.source = source
        self.feature = feature
        self.expected = expected
        self.rejected = rejected
        self.was = was
        self.decisionID = decisionID
        self.ruleID = ruleID
        self.modelID = modelID
        self.sender = sender
        self.senderDomain = senderDomain
        self.listID = listID
        self.featuresJSON = featuresJSON
        self.scope = scope
        self.createdRuleID = createdRuleID
        self.textJSON = textJSON
    }
}

public struct RuleSetVersion: Sendable, Hashable, Identifiable {
    public var version: Int
    public var origin: String
    public var bodyJSON: String
    public var digest: String
    public var note: String?
    public var createdAt: Date

    public var id: Int { version }

    public init(version: Int, origin: String, bodyJSON: String, digest: String, note: String? = nil, createdAt: Date) {
        self.version = version
        self.origin = origin
        self.bodyJSON = bodyJSON
        self.digest = digest
        self.note = note
        self.createdAt = createdAt
    }
}

public protocol ClassificationRulesStoring: Sendable {
    func head() async throws -> RuleSetVersion?
    func versions(limit: Int) async throws -> [RuleSetVersion]
    func version(_ number: Int) async throws -> RuleSetVersion?
    func append(origin: String, bodyJSON: String, digest: String, note: String?, createdAt: Date,
                historyLimit: Int) async throws -> Int
    func examples(limit: Int) async throws -> [LabelledExample]
    func addExample(_ example: LabelledExample, maxRows: Int) async throws
    func deleteExample(id: String) async throws
    func removeAllExamples() async throws
}

public actor InMemoryClassificationRulesStore: ClassificationRulesStoring {
    private var all: [RuleSetVersion] = []
    private var headVersion: Int?
    private var saved: [LabelledExample] = []

    public init() {}

    public func head() async throws -> RuleSetVersion? { all.first { $0.version == headVersion } }

    public func versions(limit: Int) async throws -> [RuleSetVersion] {
        Array(all.sorted { $0.version > $1.version }.prefix(max(0, limit)))
    }

    public func version(_ number: Int) async throws -> RuleSetVersion? { all.first { $0.version == number } }

    public func append(origin: String, bodyJSON: String, digest: String, note: String?, createdAt: Date,
                       historyLimit: Int) async throws -> Int {
        let next = (all.map(\.version).max() ?? 0) + 1
        all.append(RuleSetVersion(version: next, origin: origin, bodyJSON: bodyJSON, digest: digest, note: note,
                                  createdAt: createdAt))
        headVersion = next
        let keep = Set(all.map(\.version).sorted(by: >).prefix(max(1, historyLimit)))
        all.removeAll { !keep.contains($0.version) }
        return next
    }

    public func examples(limit: Int) async throws -> [LabelledExample] {
        Array(saved.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.prefix(max(0, limit)))
    }

    public func addExample(_ example: LabelledExample, maxRows: Int) async throws {
        saved.removeAll { $0.id == example.id }
        saved.append(example)
        if saved.count > maxRows {
            saved = Array(saved.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.prefix(max(0, maxRows)))
        }
    }

    public func deleteExample(id: String) async throws { saved.removeAll { $0.id == id } }

    public func removeAllExamples() async throws { saved = [] }
}
