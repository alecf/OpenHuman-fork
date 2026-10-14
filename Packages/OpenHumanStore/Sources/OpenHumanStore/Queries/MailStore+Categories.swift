import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    static func withCategories(_ items: [ThreadListItem], in db: Database) throws -> [ThreadListItem] {
        guard !items.isEmpty else { return items }
        let accounts = Array(Set(items.map(\.ref.accountID.rawValue))).sorted()
        let categories = try Int64.fetchAll(db, sql: """
            SELECT label_rid FROM labels WHERE account_id IN (\(marks(accounts.count))) AND kind = 'category'
            """, arguments: StatementArguments(accounts))
        guard !categories.isEmpty else { return items }
        var byThread: [Int64: [LabelRowID]] = [:]
        let tids = items.map(\.id.rawValue)
        for start in stride(from: 0, to: tids.count, by: 500) {
            let chunk = Array(tids[start..<min(start + 500, tids.count)])
            let rows = try Row.fetchAll(db, sql: """
                SELECT tid, label_rid FROM thread_labels
                WHERE tid IN (\(marks(chunk.count))) AND label_rid IN (\(marks(categories.count)))
                """, arguments: StatementArguments(chunk + categories))
            for row in rows {
                byThread[row[0] as Int64, default: []].append(LabelRowID(rawValue: row[1]))
            }
        }
        guard !byThread.isEmpty else { return items }
        return items.map { item in
            guard let rids = byThread[item.id.rawValue] else { return item }
            var copy = item
            copy.categoryLabelIDs = Array(Set(rids)).sorted { $0.rawValue < $1.rawValue }
            return copy
        }
    }

    static func withCategories(_ page: ThreadPage, in db: Database) throws -> ThreadPage {
        ThreadPage(items: try withCategories(page.items, in: db), nextCursor: page.nextCursor)
    }

    static func withCategories(_ item: ThreadListItem, in db: Database) throws -> ThreadListItem {
        try withCategories([item], in: db)[0]
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
