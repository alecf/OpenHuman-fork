import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

extension AutoLabelCenter {
    struct LogOptions {
        var enabled: Bool
        var keepText: Bool
        var maxRows: Int
        var maxDays: Int
        var salt: Data?
    }

    func logOptions() async -> LogOptions {
        let settings = environment?.settings
        func read<V>(_ key: AppSettingKey<V>) async -> V { (try? await settings?.get(key)) ?? key.defaultValue }
        var options = LogOptions(enabled: await read(AppSettings.classificationDecisionLogEnabled),
                                 keepText: await read(AppSettings.classificationKeepInputText),
                                 maxRows: max(1, await read(AppSettings.classificationDecisionLogMaxRows)),
                                 maxDays: max(1, await read(AppSettings.classificationDecisionLogMaxDays)), salt: keySalt)
        if options.salt == nil {
            var hex = await read(AppSettings.classificationKeySalt)
            if Data(classificationHex: hex) == nil {
                var generator = SystemRandomNumberGenerator()
                hex = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
                    .joined()
                try? await settings?.set(AppSettings.classificationKeySalt, hex)
            }
            keySalt = Data(classificationHex: hex)
            options.salt = keySalt
        }
        return options
    }

    var decisionLog: (any DecisionLogStoring)? { store as? any DecisionLogStoring }

    func logDecisions(_ fresh: [Decision]) async {
        guard let log = decisionLog, fresh.contains(where: { $0.context != nil }) else { return }
        let options = await logOptions()
        guard options.enabled else { return }
        let writes = writesToGmail
        let rows: [ClassificationDecision] = fresh.compactMap { decision in
            guard let context = decision.context else { return nil }
            return Self.row(decision.entry, context: context, options: options, writes: writes,
                            promptVersion: self.options.promptVersion, now: self.options.now())
        }
        try? await log.appendDecisions(rows, now: self.options.now(), maxRows: options.maxRows, maxDays: options.maxDays)
    }

    static func row(_ entry: AutoLabelEntry, context: DecisionContext, options: LogOptions, writes: Bool,
                    promptVersion: Int, now: Date) -> ClassificationDecision {
        let decidedBy: String
        switch entry.source {
        case .derived: decidedBy = "rule"
        case .model: decidedBy = "model"
        case .gmailLabel: decidedBy = "gmail_label"
        case .user: decidedBy = "user"
        }
        let isModel = entry.source == .model
        let parts = entry.modelID.split(separator: "|", maxSplits: 1).map(String.init)
        let state: DecisionAppliedState = entry.source == .gmailLabel ? .written : writes ? .pending : .localOnly
        let features = ClassificationFeatures.make(context.subject, config: context.config, salt: options.salt).json()
        var text: String?
        if options.keepText {
            let pair = ["subject": context.subject.conversation.subject,
                        "snippet": context.subject.conversation.messages.last?.text ?? ""]
            text = (try? JSONEncoder().encode(pair)).map { String(decoding: $0, as: UTF8.self) }
        }
        return ClassificationDecision(
            account: entry.account, thread: entry.thread, latestMessage: entry.latestMessage, decidedAt: now,
            decidedBy: decidedBy, ruleID: entry.ruleID ?? context.verdict.decidingRuleID,
            ruleSetVersion: context.ruleSetVersion,
            promptID: isModel ? AutoLabelPrompt.name.rawValue : nil, promptVersion: isModel ? promptVersion : nil,
            providerID: isModel ? parts.first : nil, modelID: isModel ? parts.last : nil, featuresJSON: features,
            constraintsJSON: constraints(context.verdict), modelOutput: isModel ? context.modelOutput : nil,
            outputLabel: entry.category.map { $0.lowercased() }, appliedLabel: nil, appliedState: state, textJSON: text)
    }

    static func constraints(_ verdict: RuleVerdict) -> String? {
        guard !verdict.forbidden.isEmpty else { return nil }
        struct Constraints: Encodable { var forbidden: [String]; var by: [String: [String]] }
        let value = Constraints(forbidden: verdict.forbidden.map(\.rawValue).sorted(),
                                by: verdict.forbiddenBy.mapValues { $0.map(\.rawValue) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    func noteApplied(_ entry: AutoLabelEntry, state: DecisionAppliedState) {
        guard let log = decisionLog else { return }
        Task {
            try? await log.setApplied(account: entry.account, thread: entry.thread, latestMessage: entry.latestMessage,
                                      state: state, label: entry.category?.lowercased())
        }
    }

    func noteWriteFailed(_ keys: [ThreadKey]) {
        for key in keys {
            if let entry = entries[key.account]?[key.gmailThreadID] { noteApplied(entry, state: .failed) }
        }
    }


    func recordCorrection(_ entry: AutoLabelEntry, expected: String?, source: String, scope: String = "thread") {
        guard let environment else { return }
        let key = inboxRows[entry.account]?.first { $0.id.gmailThreadID == entry.thread }?.id
            ?? lastCorrected.flatMap { $0.key.gmailThreadID == entry.thread && $0.key.account == entry.account ? $0.key : nil }
        exampleTasks.removeAll { $0.isCancelled }
        exampleTasks.append(Task { @MainActor [weak self] in
            await self?.recordExample(account: entry.account, thread: entry.thread, key: key, feature: "autolabel",
                                      expected: expected.map { $0.lowercased() } ?? "none",
                                      was: entry.category.map { $0.lowercased() } ?? "none",
                                      rejected: entry.rejected.map { $0.lowercased() }, source: source, scope: scope,
                                      ruleSet: environment.classification)
        })
    }

    public func settleCorrections() async {
        let tasks = exampleTasks
        exampleTasks = []
        for task in tasks { await task.value }
    }

    func recordExample(account: AccountID, thread: GmailThreadID, key: ThreadKey?, feature: String, expected: String,
                       was: String?, rejected: [String] = [], source: String = "correction", scope: String = "thread",
                       createdRuleID: String? = nil, ruleSet: ClassificationRuleSet) async {
        var example = LabelledExample(account: account, thread: thread, createdAt: options.now(), source: source,
                                      feature: feature, expected: expected, rejected: rejected, was: was, scope: scope,
                                      createdRuleID: createdRuleID)
        let decision = try? await decisionLog?.latestDecision(account: account, thread: thread)
        example.decisionID = decision?.id
        example.ruleID = decision?.ruleID
        example.modelID = decision?.modelID
        if let key, let data = environment?.data, let detail = await AIThreadLoader.first(data.threadDetail(key)) ?? nil,
           let latest = detail.messages.last {
            let row = inboxRows[account]?.first { $0.id == key } ?? (lastCorrected?.key == key ? (lastCorrected?.row ?? nil) : nil)
            var subject = RuleSubject(conversation: conversation(detail, signals: await signals(for: latest)),
                                      account: accounts[account]?.email,
                                      listID: (try? await data.listID(latest.id)) ?? nil)
            if let row { subject = await ruleSubject(row: row, detail: detail, latest: latest) }
            let options = await logOptions()
            example.latestMessage = latest.id.gmailMessageID
            example.sender = latest.from?.email.lowercased()
            example.senderDomain = example.sender.flatMap { $0.split(separator: "@").last.map(String.init) }
            example.listID = subject.listID
            example.featuresJSON = ClassificationFeatures.make(subject, config: ruleSet.config, salt: options.salt).json()
            if options.keepText {
                let pair = ["subject": detail.subject, "snippet": latest.snippet]
                example.textJSON = (try? JSONEncoder().encode(pair)).map { String(decoding: $0, as: UTF8.self) }
            }
        }
        await ruleSet.record(example)
    }


    public func recentDecisions(limit: Int = 200) async -> [ClassificationDecision] {
        (try? await decisionLog?.decisions(limit: limit)) ?? []
    }

    public func clearDecisionLog() async {
        try? await decisionLog?.removeAllDecisions()
    }
}

extension Data {
    init?(classificationHex hex: String) {
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
