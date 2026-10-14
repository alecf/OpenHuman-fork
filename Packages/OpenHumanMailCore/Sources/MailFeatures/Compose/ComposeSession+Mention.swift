import Foundation
import MailModel
import OpenHumanCore

@MainActor
final class MentionState {
    var range: Range<Int>?
    var query = ""
    var dismissedStart: Int?
    var task: Task<Void, Never>?
    let undoBox = MentionUndoBox()
    weak var undoManager: UndoManager?
}

@MainActor
final class MentionUndoBox {
    weak var session: ComposeSession?
}

extension ComposeSession {
    static let mentionFetchLimit = 30

    public func updateMention(in text: String, caret: Int, mayOpen: Bool) {
        guard let pending = MentionTrigger.pending(in: text, caret: caret), !pending.query.isEmpty else {
            mentionState.dismissedStart = nil
            endMention()
            return
        }
        if mentionState.dismissedStart == pending.range.lowerBound { return }
        guard mayOpen || mentionPicker != nil else { return }
        mentionState.range = pending.range
        if mentionState.query == pending.query, mentionPicker != nil { return }
        mentionState.query = pending.query
        mentionPicker?.markStale()
        loadMentions(for: pending.query)
    }

    public func dismissMention() {
        mentionState.dismissedStart = mentionState.range?.lowerBound
        mentionPicker?.close()
    }

    private func endMention() {
        mentionState.task?.cancel()
        mentionState.range = nil
        mentionState.query = ""
        mentionPicker?.close()
    }

    private func loadMentions(for query: String) {
        mentionState.task?.cancel()
        let data = services.data
        let accountID = account.id
        mentionState.task = Task { [weak self] in
            let found = (try? await data.contactSuggestions(accountID, prefix: query, limit: Self.mentionFetchLimit)) ?? []
            guard !Task.isCancelled, let self, self.mentionState.query == query else { return }
            self.showMentions(MentionRanking.rank(found, query: query, limit: MentionPickerModel.maxRows))
        }
    }

    func showMentions(_ rows: [MentionRow]) {
        guard !rows.isEmpty else {
            mentionPicker?.close()
            return
        }
        if let picker = mentionPicker {
            picker.setRows(rows, query: mentionState.query)
            return
        }
        mentionPicker = MentionPickerModel(rows: rows, query: mentionState.query, onChoose: { [weak self] row in
            self?.chooseMention(row)
        }, onClose: { [weak self] in
            self?.mentionPicker = nil
        })
    }

    func chooseMention(_ row: MentionRow) {
        guard let range = mentionState.range, let editor,
              let typed = editor.text(in: range), let first = typed.utf16.first, MentionTrigger.isTrigger(first)
        else { return }
        mentionState.range = nil
        mentionState.query = ""
        let undo = editor.editorUndoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        let name = MentionEdit.insertedName(for: row.address)
        guard editor.replaceText(in: range, with: name) else { return }
        editor.placeCaret(at: range.lowerBound + (name as NSString).length)
        addMentionRecipient(row.address, undoManager: undo)
        editor.focusEditor()
    }

    @discardableResult
    func addMentionRecipient(_ address: EmailAddress, undoManager: UndoManager?) -> Bool {
        let email = address.email.lowercased()
        guard !(to.tokens + cc.tokens + bcc.tokens).contains(where: { $0.email.lowercased() == email }) else { return false }
        to.accept(address)
        registerMentionUndo(address, added: true, in: undoManager)
        return true
    }

    private func registerMentionUndo(_ address: EmailAddress, added: Bool, in undoManager: UndoManager?) {
        guard let undoManager else { return }
        let box = mentionState.undoBox
        box.session = self
        mentionState.undoManager = undoManager
        undoManager.registerUndo(withTarget: box) { [box, weak undoManager] _ in
            MainActor.assumeIsolated {
                guard let session = box.session else { return }
                if added { session.to.remove(address) } else { session.to.accept(address) }
                session.registerMentionUndo(address, added: !added, in: undoManager)
            }
        }
    }

    public func dropMentionUndo() {
        mentionState.undoManager?.removeAllActions(withTarget: mentionState.undoBox)
        mentionState.undoManager = nil
    }
}
