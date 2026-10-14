import Foundation
import GRDB

enum OperationTargets {
    static func linkedOperations(mids: [Int64], in db: Database) throws -> Set<Int64> {
        var ops = Set<Int64>()
        for chunk in stride(from: 0, to: mids.count, by: 500).map({ Array(mids[$0..<min($0 + 500, mids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            ops.formUnion(try Int64.fetchAll(db, sql: "SELECT op_id FROM pending_op_messages WHERE mid IN (\(marks))",
                                             arguments: StatementArguments(chunk)))
        }
        return ops
    }

    @discardableResult
    static func cancelOrphans(_ ops: Set<Int64>, in db: Database) throws -> Int {
        var cancelled = 0
        for op in ops.sorted() {
            try db.execute(sql: """
                UPDATE pending_operations
                SET status = 'cancelled', claimed_by = NULL, last_error_code = 'target_gone',
                    last_error_message = 'the messages it targets no longer exist', updated_at = ?
                WHERE op_id = ? AND status = 'pending' AND kind IN ('modify_labels', 'trash', 'untrash')
                  AND NOT EXISTS (SELECT 1 FROM pending_op_messages WHERE op_id = ?)
                """, arguments: [nowMillis(), op, op])
            cancelled += db.changesCount
        }
        return cancelled
    }
}
