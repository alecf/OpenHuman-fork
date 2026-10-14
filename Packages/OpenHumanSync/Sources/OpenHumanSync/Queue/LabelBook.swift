import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

struct LabelBook: Sendable {
    struct Unresolved: Error, Equatable, Sendable { var name: String }

    let account: AccountID
    let store: MailStore
    let api: any GmailAPI

    func knownIDs() throws -> [String: String] {
        var ids: [String: String] = [:]
        for label in try gmailLabels() { ids[label.name] = label.key }
        return ids
    }

    func names(of ids: [String]) throws -> [String: String] {
        var byName: [String: String] = [:]
        for id in ids {
            if let label = try store.label(account: account, key: id) { byName[label.name] = id }
        }
        return byName
    }

    private func gmailLabels() throws -> [LabelItem] {
        try store.labels(account: account).filter { $0.kind != .virtual && $0.kind != .split }
    }

    func ensure(_ names: [String], report: inout OperationDrainer.PassReport) async throws -> [String] {
        guard !names.isEmpty else { return [] }
        var known = try knownIDs()
        var ids: [String] = []
        for name in names {
            if let id = known[name] { ids.append(id); continue }
            let label = try await create(name, report: &report)
            try store.upsertLabels([GmailMapper.labelUpsert(label)], account: account, removeMissing: false)
            known[label.name] = label.id
            ids.append(label.id)
        }
        return ids
    }

    func create(_ name: String, report: inout OperationDrainer.PassReport) async throws -> GmailLabel {
        let visibility = Self.visibility(for: name)
        do {
            report.gmailCalls += 1
            return try await api.createLabel(name: name, labelListVisibility: visibility.labelList,
                                             messageListVisibility: visibility.messageList)
        } catch GmailError.badRequest(let reason, _) where reason == "conflict" {
            report.gmailCalls += 1
            let all = try await api.listLabels()
            if let existing = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
            throw Unresolved(name: name)
        }
    }

    static func visibility(for name: String) -> (labelList: String?, messageList: String?) {
        if OHGmailLabels.autoLabelCategory(inLabelName: name) != nil {
            return AutoLabelVisibility.showInGmail ? ("labelShow", "show") : ("labelHide", "hide")
        }
        switch ScheduleLabel.parse(name) {
        case .schedule: return ("labelHide", "hide")
        case .marker: return ("labelShow", "hide")
        case .malformed, .notOurs: return (nil, nil)
        }
    }
}
