import Foundation
import GRDB

enum SearchDocuments {
    struct Document: Equatable {
        var subject: String
        var participants: String
        var body: String
        var attachmentNames: String
    }

    struct Update {
        var subject: String?
        var participants: [EmailAddressLine]?
        var bodyText: String?
        var snippet: String?
        var attachmentNames: [String]?
        var hasStoredBody: Bool?
    }

    struct EmailAddressLine { var name: String?; var email: String }

    static func participants(from: EmailAddressLine?, to: [EmailAddressLine], cc: [EmailAddressLine]) -> [EmailAddressLine] {
        (from.map { [$0] } ?? []) + to + cc
    }

    static func write(mid: Int64, _ update: Update, in db: Database) throws {
        let current = try Row.fetchOne(db.cached("""
            SELECT subject, participants, body, attachment_names FROM message_search_docs WHERE mid = ?
            """), arguments: [mid]).map {
            Document(subject: $0["subject"], participants: $0["participants"], body: $0["body"],
                     attachmentNames: $0["attachment_names"])
        }
        var doc: Document
        if let current {
            doc = current
        } else if update.subject != nil, update.participants != nil {
            doc = Document(subject: "", participants: "", body: "", attachmentNames: "")
        } else {
            doc = try seed(mid: mid, in: db)
        }
        if let subject = update.subject { doc.subject = SearchTextNormalizer.normalizeField(subject) }
        if let lines = update.participants { doc.participants = render(lines) }
        if let body = update.bodyText {
            doc.body = SearchTextNormalizer.normalizeBody(body)
        } else if let snippet = update.snippet, try !(update.hasStoredBody ?? hasStoredBody(mid: mid, in: db)) {
            doc.body = SearchTextNormalizer.normalizeBody(HTMLEntities.decode(snippet))
        }
        if let names = update.attachmentNames {
            doc.attachmentNames = names.map(SearchTextNormalizer.normalizeField).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard doc != current else { return }
        try db.cached("""
            INSERT INTO message_search_docs (mid, subject, participants, body, attachment_names) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (mid) DO UPDATE SET subject = excluded.subject, participants = excluded.participants,
                body = excluded.body, attachment_names = excluded.attachment_names
            """).execute(arguments: [mid, doc.subject, doc.participants, doc.body, doc.attachmentNames])
    }

    private static func render(_ lines: [EmailAddressLine]) -> String {
        lines.compactMap { line -> String? in
            let email = SearchTextNormalizer.normalizeField(line.email)
            let name = line.name.map(SearchTextNormalizer.normalizeField) ?? ""
            if email.isEmpty { return name.isEmpty ? nil : name }
            return name.isEmpty ? "<\(email)>" : "\(name) <\(email)>"
        }.joined(separator: "\n")
    }

    private static func seed(mid: Int64, in db: Database) throws -> Document {
        guard let r = try Row.fetchOne(db.cached("""
            SELECT subject, snippet, from_name, from_email, to_json, cc_json FROM messages WHERE mid = ?
            """), arguments: [mid]) else { return Document(subject: "", participants: "", body: "", attachmentNames: "") }
        let from: String? = r["from_email"]
        let lines = participants(from: from.map { EmailAddressLine(name: r["from_name"], email: $0) },
                                 to: WireAddress.decode(r["to_json"]).map { EmailAddressLine(name: $0.n, email: $0.e) },
                                 cc: WireAddress.decode(r["cc_json"]).map { EmailAddressLine(name: $0.n, email: $0.e) })
        let names = try String.fetchAll(db.cached("SELECT filename FROM attachments WHERE mid = ? ORDER BY aid"), arguments: [mid])
        return Document(subject: SearchTextNormalizer.normalizeField(r["subject"]), participants: render(lines),
                        body: SearchTextNormalizer.normalizeBody(HTMLEntities.decode(r["snippet"])),
                        attachmentNames: names.map(SearchTextNormalizer.normalizeField).filter { !$0.isEmpty }
                            .joined(separator: "\n"))
    }

    private static func hasStoredBody(mid: Int64, in db: Database) throws -> Bool {
        try Int.fetchOne(db.cached("SELECT body_state FROM messages WHERE mid = ?"), arguments: [mid]) == BodyState.stored.rawValue
    }
}
