import Foundation
import GRDB

enum AttachmentRows {
    static func replace(mid: Int64, account: Int64, _ attachments: [AttachmentUpsert], in db: Database) throws {
        var keep = Set<String>()
        for a in attachments where keep.insert(a.partID).inserted {
            try db.cached("""
                INSERT INTO attachments (mid, account_id, part_id, gmail_attachment_id, filename, mime_type, size,
                                         content_id, is_inline)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (mid, part_id) DO UPDATE SET gmail_attachment_id = excluded.gmail_attachment_id,
                    filename = excluded.filename, mime_type = excluded.mime_type, size = excluded.size,
                    content_id = excluded.content_id, is_inline = excluded.is_inline
                """).execute(arguments: [mid, account, a.partID, a.gmailAttachmentID, a.filename,
                                 a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType, max(a.size, 0),
                                 a.contentID.map(stripBrackets), a.isInline])
        }
        let existing = try String.fetchAll(db.cached("SELECT part_id FROM attachments WHERE mid = ?"), arguments: [mid])
        for part in existing where !keep.contains(part) {
            try db.cached("DELETE FROM attachments WHERE mid = ? AND part_id = ?").execute(arguments: [mid, part])
        }
    }

    static func hasAttachments(_ attachments: [AttachmentUpsert]) -> Bool {
        attachments.contains { !$0.isInline }
    }

    static func stripBrackets(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }
}
