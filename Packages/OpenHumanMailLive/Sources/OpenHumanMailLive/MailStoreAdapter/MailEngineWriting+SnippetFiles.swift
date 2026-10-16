import Foundation
import MailModel
import OpenHumanStore
import OpenHumanSync

extension MailEngineWriting {
    public func storeSnippetAttachment(file: URL, mimeType: String) async throws -> SnippetAttachment {
        throw MailPortError.unsupported("snippet attachments")
    }

    public func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachment {
        throw MailPortError.unsupported("snippet attachments")
    }

    public func snippetFileURL(_ attachment: SnippetAttachment) -> URL? { nil }
}
