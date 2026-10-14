import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

enum MuteRule {
    static let inbox = GmailLabelID("INBOX")

    @discardableResult
    static func apply(arrived: [GmailMessage], account: AccountID, store: any MailReading,
                      mutating: any MailMutating) throws -> Int {
        let candidates = arrived.filter { ($0.labelIds ?? []).contains(inbox.rawValue) && $0.threadId != nil }
        guard !candidates.isEmpty, let muted = try mutedLabel(account: account, store: store) else { return 0 }
        let newByThread = Dictionary(grouping: candidates, by: { $0.threadId ?? "" }).mapValues { Set($0.map(\.id)) }
        var targets: [GmailMessageID] = []
        for (thread, new) in newByThread.sorted(by: { $0.key < $1.key }) {
            guard let ref = try store.thread(account: account, gmailThreadID: GmailThreadID(thread)),
                  let detail = try store.threadDetail(ref.rowID) else { continue }
            targets += refiled(detail.messages, muted: muted).filter { new.contains($0.rawValue) }
        }
        return try queue(targets, account: account, muted: muted, mutating: mutating)
    }

    @discardableResult
    static func recheck(account: AccountID, store: any SyncStore, mutating: any MailMutating) throws -> Int {
        guard let muted = try mutedLabel(account: account, store: store) else { return 0 }
        var targets: [GmailMessageID] = []
        for ref in try store.inboxThreads(account: account, labelled: muted) {
            guard let detail = try store.threadDetail(ref.rowID) else { continue }
            targets += refiled(detail.messages, muted: muted)
        }
        guard !targets.isEmpty else { return 0 }
        let failed = try failedTargets(account: account, store: store, muted: muted)
        return try queue(targets.filter { !failed.contains($0) }, account: account, muted: muted, mutating: mutating)
    }

    static func mutedLabel(account: AccountID, store: any MailReading) throws -> GmailLabelID? {
        try store.labels(account: account).first(where: { $0.name == OHGmailLabels.muted }).map { GmailLabelID($0.key) }
    }

    static func refiled(_ messages: [MessageItem], muted: GmailLabelID) -> [GmailMessageID] {
        let visible = messages.filter { !$0.isDraft && !$0.inTrash && !$0.inSpam }
        guard visible.contains(where: { $0.labelIDs.contains(muted) }) else { return [] }
        return visible.filter { $0.labelIDs.contains(inbox) && !$0.labelIDs.contains(muted) }.map(\.gmailMessageID)
    }

    static func failedTargets(account: AccountID, store: any MailReading, muted: GmailLabelID) throws -> Set<GmailMessageID> {
        var ids = Set<GmailMessageID>()
        for op in try store.operations(account: account, statuses: [.failed], limit: 500) where op.origin == .scheduler {
            if case let .modifyLabels(targets, add, remove, _) = op.payload, add == [muted], remove == [inbox] {
                ids.formUnion(targets)
            }
        }
        return ids
    }

    private static func queue(_ targets: [GmailMessageID], account: AccountID, muted: GmailLabelID,
                              mutating: any MailMutating) throws -> Int {
        guard !targets.isEmpty else { return 0 }
        _ = try mutating.apply(.modifyMessageLabels(account, targets, add: [muted], remove: [inbox]), origin: .scheduler)
        return targets.count
    }
}
