import Foundation
import GRDB
import OpenHumanCore

enum OperationPayloadCodec {
    private struct Wire: Codable {
        var ids: [String]?
        var add: [String]?
        var remove: [String]?
        var addNames: [String]?
        var draftID: String?
        var version: Int?
        var gmailDraftID: String?
        var name: String?
    }

    static func kind(of payload: OperationPayload) -> OperationKind {
        switch payload {
        case .modifyLabels: return .modifyLabels
        case .trash: return .trash
        case .untrash: return .untrash
        case .upsertDraft: return .upsertDraft
        case .deleteDraft: return .deleteDraft
        case .sendDraft: return .sendDraft
        case .createLabel: return .createLabel
        }
    }

    static func encode(_ payload: OperationPayload) -> String {
        var w = Wire()
        switch payload {
        case let .modifyLabels(ids, add, remove, addNames):
            w.ids = ids.map(\.rawValue); w.add = add.map(\.rawValue); w.remove = remove.map(\.rawValue)
            if !addNames.isEmpty { w.addNames = addNames }
        case let .trash(ids), let .untrash(ids):
            w.ids = ids.map(\.rawValue)
        case let .upsertDraft(draftID, version):
            w.draftID = draftID.rawValue; w.version = version
        case let .deleteDraft(draftID, gmailDraftID):
            w.draftID = draftID.rawValue; w.gmailDraftID = gmailDraftID?.rawValue
        case let .sendDraft(draftID):
            w.draftID = draftID.rawValue
        case let .createLabel(name):
            w.name = name
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(w)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decode(kind: OperationKind, json: String) throws -> OperationPayload {
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else {
            throw StoreError.integrity("pending_operations.payload_json is not valid JSON for \(kind.rawValue)")
        }
        func ids() -> [GmailMessageID] { (w.ids ?? []).map { GmailMessageID($0) } }
        func draft() throws -> DraftID {
            guard let d = w.draftID else { throw StoreError.integrity("\(kind.rawValue) payload without draftID") }
            return DraftID(d)
        }
        switch kind {
        case .modifyLabels:
            return .modifyLabels(ids: ids(), add: (w.add ?? []).map { GmailLabelID($0) },
                                 remove: (w.remove ?? []).map { GmailLabelID($0) }, addNames: w.addNames ?? [])
        case .trash: return .trash(ids: ids())
        case .untrash: return .untrash(ids: ids())
        case .upsertDraft: return .upsertDraft(draftID: try draft(), version: w.version ?? 0)
        case .deleteDraft: return .deleteDraft(draftID: try draft(), gmailDraftID: w.gmailDraftID.map { GmailDraftID($0) })
        case .sendDraft: return .sendDraft(draftID: try draft())
        case .createLabel:
            guard let name = w.name else { throw StoreError.integrity("create_label payload without name") }
            return .createLabel(name: name)
        }
    }

    // Ops adding labels by name append `addNames`, so a snooze to 9:00 never shares a call with one to 10:00
    static func labelsCoalesceKey(account: AccountID, add: [GmailLabelID], remove: [GmailLabelID],
                                  addNames: [String] = []) -> String {
        let a = add.map(\.rawValue).sorted().joined(separator: ",")
        let r = remove.map(\.rawValue).sorted().joined(separator: ",")
        let key = "labels:\(account.rawValue):\(a)|\(r)"
        return addNames.isEmpty ? key : key + "|" + addNames.sorted().joined(separator: ",")
    }
}

extension MailStore {
    static func storeDate(millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
    static func storeMillis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func operationItem(_ r: Row) throws -> OperationItem {
        guard let kind = OperationKind(rawValue: r["kind"]), let status = OperationStatus(rawValue: r["status"]),
              let origin = OperationOrigin(rawValue: r["origin"]) else {
            throw StoreError.integrity("pending_operations row \(r["op_id"] as Int64? ?? -1) has an unknown enum value")
        }
        let depends: Int64? = r["depends_on"]
        return OperationItem(
            id: OperationID(rawValue: r["op_id"]), accountID: AccountID(r["account_id"]), kind: kind,
            payload: try OperationPayloadCodec.decode(kind: kind, json: r["payload_json"]), status: status,
            attempts: r["attempts"], notBefore: storeDate(millis: r["not_before"]), nextRetryAt: storeDate(millis: r["next_retry_at"]),
            dependsOn: depends.map { OperationID(rawValue: $0) }, coalesceKey: r["coalesce_key"], origin: origin,
            lastErrorCode: r["last_error_code"], lastErrorMessage: r["last_error_message"],
            createdAt: storeDate(millis: r["created_at"]), updatedAt: storeDate(millis: r["updated_at"]))
    }

    static func operationItem(id: Int64, in db: Database) throws -> OperationItem? {
        try Row.fetchOne(db, sql: "SELECT * FROM pending_operations WHERE op_id = ?", arguments: [id]).map(operationItem)
    }
}
