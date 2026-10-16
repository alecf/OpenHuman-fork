import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import OpenHumanSync

extension MailEngineWriting {
    public func scheduleSend(_ id: DraftID, at: Date, onlyIfNoReply: Bool) async throws {
        guard !onlyIfNoReply else { throw MailPortError.unsupported("send later only if no reply") }
        try await scheduleSend(id, at: at)
    }
}
