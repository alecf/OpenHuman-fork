import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

struct DrainContext: Sendable {
    let account: AccountID
    let store: MailStore
    let api: any GmailAPI
    let clock: any OHClock
    let labels: LabelBook
    let log = Log(.queue)

    init(account: AccountID, store: MailStore, api: any GmailAPI, clock: any OHClock) {
        self.account = account
        self.store = store
        self.api = api
        self.clock = clock
        labels = LabelBook(account: account, store: store, api: api)
    }

    func message(for draft: DraftListItem) async throws -> DraftMessage {
        let item = try store.accounts().first { $0.id == account }
        return try await DraftMessage.make(draft, account: item, date: clock.now) { attachment in
            try await self.attachmentData(attachment, of: draft)
        }
    }

    func attachmentData(_ attachment: DraftAttachment, of draft: DraftListItem) async throws -> Data {
        let index = (draft.content.attachments.firstIndex(of: attachment) ?? 0) + 1
        if let path = attachment.localPath {
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty,
                  let data = try? Data(contentsOf: store.location.directory.appendingPathComponent(path)) else {
                throw DraftMessage.Failure.attachmentMissing("attachment \(index): local file missing")
            }
            return data
        }
        guard let aid = attachment.sourceAttachmentID, let source = draft.replyToMessageID else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): no source")
        }
        let fetcher = AttachmentFetcher(account: account, store: store, api: api, storeDirectory: store.location.directory)
        let file = try await fetcher.attachmentFile(message: source, attachment: aid, priority: .queue)
        guard let data = try? Data(contentsOf: file) else {
            throw DraftMessage.Failure.attachmentMissing("attachment \(index): cached file unreadable")
        }
        return data
    }

    func labelNames(ofMessage id: GmailMessageID?) throws -> [String] {
        guard let id, let item = try store.message(account: account, gmailMessageID: id) else { return [] }
        return try labels.names(of: item.labelIDs.map(\.rawValue)).keys.sorted()
    }
}
