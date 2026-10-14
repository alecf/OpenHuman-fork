import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

extension AutoLabelCenter {
    struct DecisionContext {
        var verdict: RuleVerdict
        var subject: RuleSubject
        var config: ClassificationConfig
        var ruleSetVersion: Int
        var modelOutput: String?
    }

    func rulesVerdict(row: ThreadRow, detail: ConversationDetail, latest: MessageSummary, rejected: [String],
                      senderRejections: Bool = true) async -> DecisionContext {
        let subject = await ruleSubject(row: row, detail: detail, latest: latest)
        let account = row.id.account
        let sender = latest.from?.email.lowercased() ?? ""
        let refused: Set<String> = senderRejections && !sender.isEmpty
            ? environment?.learning.rejectedAutoLabels(account: account, sender: sender) ?? [] : []
        let rules = environment?.classification
        let config = rules?.config ?? .shipped
        let verdict = RuleEngine.evaluate(config, subject,
                                          rejected: Set(rejected.compactMap(AutoLabelCategory.init(title:))),
                                          senderRejected: Set(refused.compactMap(AutoLabelCategory.init(title:))))
        return DecisionContext(verdict: verdict, subject: subject, config: config, ruleSetVersion: rules?.version ?? 0)
    }

    func ruleSubject(row: ThreadRow, detail: ConversationDetail, latest: MessageSummary) async -> RuleSubject {
        let account = row.id.account
        var listID: String?
        if let data = environment?.data { listID = (try? await data.listID(latest.id)) ?? nil }
        let names = row.userLabelIDs.compactMap { id in labels[account]?.first { $0.id == id }?.name }
        return RuleSubject(conversation: conversation(detail, signals: await signals(for: latest)),
                           account: accounts[account]?.email, listID: listID, gmailImportant: row.isImportant,
                           gmailLabels: names, hasAttachments: row.attachmentCount > 0,
                           currentLabel: entries[account]?[row.id.gmailThreadID]?.category
                               .flatMap(AutoLabelCategory.init(title:)))
    }

    func rulesChanged() {
        guard isOn else { return }
        for rows in inboxRows.values {
            for row in rows where inScope(row) { seen[row.id] = nil }
        }
        enqueueInScope()
    }

    public var accountAddresses: [String] { accounts.values.map { $0.email.lowercased() }.sorted() }

    public func resortInScope() async {
        rulesChanged()
        await kick().value
    }
}
