import Foundation
import MailModel
import OpenHumanCore

public struct PendingSendDone: Codable, Sendable, Hashable {
    public var draft: DraftKey
    public var thread: ThreadKey

    public init(draft: DraftKey, thread: ThreadKey) {
        self.draft = draft
        self.thread = thread
    }
}

extension ComposeSettings {
    public static let pendingSendDone = AppSettingKey<[PendingSendDone]>(name: "compose.pending_send_done",
                                                                         defaultValue: [])
}

struct ArchivedBySend {
    var thread: ThreadKey
    var entry: UUID?
}

extension ComposeManager {
    static func archives(from location: MailLocation?) -> Bool {
        switch location {
        case .system(.sent)?, .system(.drafts)?, .system(.trash)?, .system(.spam)?, .system(.scheduled)?,
             .system(.snoozed)?, .reviewQueue?:
            false
        default:
            true
        }
    }

    public func archivesOnSend(_ session: ComposeSession) -> Bool {
        guard let thread = session.thread, session.mode == .reply || session.mode == .replyAll || session.mode == .forward
        else { return false }
        return Self.archives(from: environment.router.accounts.first { $0.id == thread.account }?.location)
    }

    func marksDoneWhenSent(_ session: ComposeSession) async -> Bool {
        guard archivesOnSend(session) else { return false }
        return await Self.read(environment.settings, AppSettings.sendAndMarkDone) ?? true
    }

    func archiveAfterSend(_ intent: PendingSendDone) async {
        let undo = environment.undo
        let before = undo?.stack.last?.id
        archivedBySend[intent.draft] = ArchivedBySend(thread: intent.thread, entry: nil)
        updatePendingSendDone { list in list.filter { $0.draft != intent.draft } + [intent] }
        if let task = environment.actions.threadActions?.markDone([intent.thread], host: environment.router) {
            await task.value
        }
        if let entry = undo?.stack.last, entry.id != before, entry.threads == [intent.thread] {
            archivedBySend[intent.draft]?.entry = entry.id
        } else if undo != nil {
            archivedBySend[intent.draft] = nil
            updatePendingSendDone { list in list.filter { $0.draft != intent.draft } }
        }
    }

    func releaseSendDone(_ draft: DraftKey) {
        archivedBySend[draft] = nil
        updatePendingSendDone { list in list.filter { $0.draft != draft } }
        forgetSendReminder(draft)
    }

    func forgetSendDone(_ draft: DraftKey) {
        let archived = archivedBySend.removeValue(forKey: draft)
        updatePendingSendDone { list in list.filter { $0.draft != draft } }
        forgetSendReminder(draft)
        if let archived { restore(archived.thread, entry: archived.entry) }
    }

    func sendWentOut(_ draft: DraftKey, thread: ThreadKey?) {
        guard archivedBySend.removeValue(forKey: draft) != nil else { return }
        updatePendingSendDone { list in list.filter { $0.draft != draft } }
    }

    private func restore(_ thread: ThreadKey, entry: UUID?) {
        track(Task { @MainActor [weak self] in
            guard let self else { return }
            if let entry, let undo = environment.undo, undo.stack.contains(where: { $0.id == entry }) {
                var waited = 0
                while undo.isWorking, waited < 400 { try? await Task.sleep(for: .milliseconds(5)); waited += 1 }
                await undo.undo(entryID: entry)
            } else if let commands = environment.commands {
                _ = try? await commands.apply(.moveToInbox([thread]))
            }
        })
    }

    func resumePendingSendDone() {
        guard canSend else { return }
        updatePendingSendDone { [weak self] list in
            guard let self else { return list }
            for intent in list where self.archivedBySend[intent.draft] == nil { self.track(self.follow(intent)) }
            return list
        }
    }

    private func follow(_ intent: PendingSendDone) -> Task<Void, Never> {
        let stream = environment.data.draft(intent.draft)
        return Task { [weak self] in
            do {
                for try await row in stream {
                    guard let self else { return }
                    switch row?.status {
                    case nil, .sent?:
                        self.releaseSendDone(intent.draft)
                        return
                    case .sending?:
                        continue
                    case .scheduled?:
                        self.releaseSendDone(intent.draft)
                        return
                    case .editing?, .failed?, .discarded?:
                        self.restore(intent.thread, entry: nil)
                        self.releaseSendDone(intent.draft)
                        return
                    }
                }
            } catch {}
        }
    }

    @discardableResult
    func updatePendingSendDone(
        _ change: @escaping @MainActor ([PendingSendDone]) -> [PendingSendDone]
    ) -> Task<Void, Never> {
        let previous = sendDoneUpdate
        let settings = environment.settings
        let task = Task { @MainActor in
            await previous?.value
            guard let settings else { return }
            let list = (try? await settings.get(ComposeSettings.pendingSendDone)) ?? []
            let next = change(list)
            if next != list { try? await settings.set(ComposeSettings.pendingSendDone, next) }
        }
        sendDoneUpdate = task
        track(task)
        return task
    }
}
