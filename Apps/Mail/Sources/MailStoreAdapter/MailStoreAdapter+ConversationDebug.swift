import Foundation
import MailModel
import OpenHumanStore

extension MailStoreAdapter {
    public func conversationDebugFacts(_ key: ThreadKey) async throws -> ConversationDebugStoreFacts? {
        var detail: ThreadDetail?
        for try await value in store.observeThreadDetail(ThreadRowID(rawValue: key.rowID)).values() {
            detail = value
            break
        }
        guard let detail else { return nil }
        let messages = detail.messages.filter { !$0.isDraft }.map { item -> ConversationDebugStoreMessage in
            let state: String = switch item.bodyState {
            case .none: "none"
            case .metadataOnly: "metadata"
            case .stored: "full"
            case .failed: "failed"
            }
            let parts = item.attachments.map {
                ConversationDebugMimePart(contentType: $0.mimeType, size: $0.size,
                                          fileExtension: Self.debugExtension($0.filename))
            }
            return ConversationDebugStoreMessage(
                message: MessageKey(account: key.account, rowID: item.id.rawValue, gmailMessageID: item.gmailMessageID),
                labelIDs: item.labelIDs.map(\.rawValue), bodyState: state, mimeParts: parts.isEmpty ? nil : parts,
                isFromMe: item.isFromMe, hasAttachments: !item.attachments.isEmpty)
        }
        return ConversationDebugStoreFacts(messages: messages)
    }

    static func debugExtension(_ filename: String) -> String? {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? ext : nil
    }
}
