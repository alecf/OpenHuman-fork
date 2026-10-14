import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public typealias BlockStoring = MailMutating & SettingsStoring & MailSearching & MailReading

enum BlockIngest {
    static let inbox = GmailLabelID("INBOX")
    static let unread = GmailLabelID("UNREAD")
    static let trash = GmailLabelID("TRASH")

    static func rulesKey() -> SettingKey<[BlockRule]> {
        SettingKey(name: BlockSettingNames.rules, defaultValue: [], isSafetyKey: false)
    }

    static func dispositionKey() -> SettingKey<BlockDisposition> {
        SettingKey(name: BlockSettingNames.defaultDisposition, defaultValue: .archive, isSafetyKey: false)
    }

    static func checkedKey() -> SettingKey<Int64> {
        SettingKey(name: BlockSettingNames.checkedThrough, defaultValue: 0, isSafetyKey: false)
    }

    static let recheckLimit = 100

    struct Plan: Equatable {
        var archive: [GmailMessageID] = []
        var trash: [GmailMessageID] = []
        var isEmpty: Bool { archive.isEmpty && trash.isEmpty }
    }

    static func plan(arrived: [GmailMessage], rules: [BlockRule], defaultDisposition: BlockDisposition) -> Plan {
        guard !rules.isEmpty else { return Plan() }
        var plan = Plan()
        for message in arrived {
            let from = message.payload?.headers?.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }
                .flatMap { BlockMatcher.address(fromHeader: $0.value) }
            switch BlockMatcher.decide(from: from, labelIDs: message.labelIds ?? [], rules: rules,
                                       defaultDisposition: defaultDisposition) {
            case .keep: break
            case .archive: plan.archive.append(GmailMessageID(message.id))
            case .trash: plan.trash.append(GmailMessageID(message.id))
            }
        }
        return plan
    }

    @discardableResult
    static func apply(arrived: [GmailMessage], account: AccountID, store: any SettingsStoring,
                      mutating: any MailMutating) throws -> Int {
        guard !arrived.isEmpty else { return 0 }
        let rules = try store.setting(rulesKey(), scope: .account(account))
        guard !rules.isEmpty else { return 0 }
        let fallback = try store.setting(dispositionKey(), scope: .global)
        return try queue(plan(arrived: arrived, rules: rules, defaultDisposition: fallback), account: account,
                         mutating: mutating)
    }

    @discardableResult
    static func recheck(account: AccountID, store: any BlockStoring, mutating: any MailMutating) throws -> Int {
        let rules = try store.setting(rulesKey(), scope: .account(account))
        guard !rules.isEmpty else { return 0 }
        let checked = try store.setting(checkedKey(), scope: .account(account))
        let fallback = try store.setting(dispositionKey(), scope: .global)
        var plan = Plan()
        var newest = checked
        var seen = Set<GmailMessageID>()
        for rule in rules {
            let since = max(checked + 1, millis(rule.createdAt))
            guard let text = BlockMatcher.recheckQuery(kind: rule.kind, value: rule.value,
                                                       since: Date(timeIntervalSince1970: Double(since) / 1000)) else { continue }
            let page = try store.search(try store.parseSearch(text), accounts: [account], after: nil, limit: recheckLimit)
            for hit in page.hits {
                guard let detail = try store.threadDetail(hit.thread.ref.rowID) else { continue }
                for message in detail.messages where !message.isDraft && seen.insert(message.gmailMessageID).inserted {
                    let date = millis(message.date)
                    guard date > checked, let from = message.from?.email,
                          let deciding = BlockMatcher.firstMatch(in: rules, address: from),
                          date >= millis(deciding.createdAt) else { continue }
                    newest = max(newest, date)
                    switch BlockMatcher.decide(from: from, labelIDs: message.labelIDs.map(\.rawValue), rules: rules,
                                               defaultDisposition: fallback) {
                    case .keep: break
                    case .archive: plan.archive.append(message.gmailMessageID)
                    case .trash: plan.trash.append(message.gmailMessageID)
                    }
                }
            }
        }
        let changed = try queue(plan, account: account, mutating: mutating)
        if newest > checked { try store.setSetting(checkedKey(), newest, scope: .account(account)) }
        return changed
    }

    private static func queue(_ plan: Plan, account: AccountID, mutating: any MailMutating) throws -> Int {
        if !plan.archive.isEmpty {
            _ = try mutating.apply(.modifyMessageLabels(account, plan.archive, add: [], remove: [inbox, unread]),
                                   origin: .scheduler)
        }
        if !plan.trash.isEmpty {
            _ = try mutating.apply(.modifyMessageLabels(account, plan.trash, add: [trash], remove: [inbox]),
                                   origin: .scheduler)
        }
        return plan.archive.count + plan.trash.count
    }

    private static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    static func isBlockOp(add: [GmailLabelID], remove: [GmailLabelID]) -> Bool {
        let removed = Set(remove.map(\.rawValue))
        let added = Set(add.map(\.rawValue))
        let archive = added.isEmpty && removed == ["INBOX", "UNREAD"]
        let trashing = added == ["TRASH"] && removed == ["INBOX"]
        return archive || trashing
    }
}
