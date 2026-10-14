import Foundation
import GRDB
import OpenHumanCore

enum LabelCreation {
    static func create(account: AccountID, name: String, applyTo: [ThreadRef], origin: OperationOrigin,
                       in db: Database) throws -> ActionReceipt {
        try MailStore.requireWritableAccount(account, in: db)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw StoreError.conflict("label name is empty") }
        guard ScheduleLabel.parse(label) == .notOurs else { throw StoreError.reservedLabel(label) }
        if let other = applyTo.first(where: { $0.accountID != account }) {
            throw StoreError.conflict("thread \(other.rowID.rawValue) belongs to another account")
        }
        let a = account.rawValue
        let index = try LabelIndex.load(account: a, in: db)
        let undo: MailAction = .modifyLabels(applyTo, add: [], remove: [GmailLabelID(label)])
        if let key = index.keyByName[label] {
            guard !applyTo.isEmpty else { return ActionReceipt(operationIDs: []) }
            return try ThreadActions.labels(applyTo, add: [key], remove: [], scope: .visibleElseNonDraft, origin: origin,
                                            undo: undo, in: db)
        }
        let (createID, inserted) = try SnoozeMutations.ensureCreateLabel(label, account: a, origin: origin, after: nil, in: db)
        var ops = inserted ? [OperationID(rawValue: createID)] : []
        let targets = try Targets.select(account: a, tids: applyTo.map(\.rowID.rawValue), scope: .visibleElseNonDraft, in: db)
        var applied = false
        if !targets.isEmpty {
            let op = try OpWriter.modifyLabels(account: a, targets: targets, add: [], remove: [], addNames: [label],
                                               origin: origin, dependsOn: createID, in: db)
            ops.append(OperationID(rawValue: op))
            applied = true
            try LabelOverlay.recompute(mids: Set(targets.map(\.mid)), in: db)
            try ThreadAggregator.refresh(tids: Set(targets.map(\.tid)), in: db)
        }
        return ActionReceipt(operationIDs: ops, undo: applied ? undo : nil)
    }
}
