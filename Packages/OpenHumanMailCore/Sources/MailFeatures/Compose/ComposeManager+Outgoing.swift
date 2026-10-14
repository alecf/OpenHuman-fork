import Foundation
import MailActions
import MailModel
import OpenHumanCore

public struct OutgoingMessage: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case undoable
        case sending
        case sent
    }

    public let id: UUID
    public let thread: ThreadKey
    public let mode: DraftMode
    public let from: EmailAddress
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let text: String
    public let date: Date
    public let earlierMessages: Set<MessageKey>
    public internal(set) var state: State

    public init(id: UUID, thread: ThreadKey, mode: DraftMode, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress],
                text: String, date: Date, earlierMessages: Set<MessageKey>, state: State) {
        self.id = id
        self.thread = thread
        self.mode = mode
        self.from = from
        self.to = to
        self.cc = cc
        self.text = text
        self.date = date
        self.earlierMessages = earlierMessages
        self.state = state
    }
}

extension ComposeManager {
    static let outgoingLimit = 20

    public func outgoingMessages(in thread: ThreadKey, shown messages: [MessageKey]) -> [OutgoingMessage] {
        outgoing.filter { entry in
            entry.thread == thread && (entry.state == .undoable || messages.allSatisfy(entry.earlierMessages.contains))
        }
    }

    func knownMessages(in thread: ThreadKey) async -> Set<MessageKey> {
        if let reader = environment.router.active?.reader, reader.thread == thread {
            return Set(reader.messages.map(\.id) + reader.pendingMessages)
        }
        let detail = await Self.first(environment.data.threadDetail(thread)) ?? nil
        return Set(detail?.messages.map(\.id) ?? [])
    }

    func addOutgoing(_ session: ComposeSession, earlier: Set<MessageKey>) {
        guard let thread = session.thread, session.mode != .new else { return }
        outgoing.removeAll { $0.id == session.id }
        outgoing.append(OutgoingMessage(id: session.id, thread: thread, mode: session.mode, from: session.from.address,
                                        to: session.to.tokens, cc: session.cc.tokens, text: session.plainText,
                                        date: timing.now(), earlierMessages: earlier, state: .undoable))
        while outgoing.count > Self.outgoingLimit {
            if let sent = outgoing.firstIndex(where: { $0.state == .sent }) { outgoing.remove(at: sent) } else { outgoing.removeFirst() }
        }
    }

    func setOutgoing(_ id: UUID, _ state: OutgoingMessage.State?) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        if let state {
            if outgoing[index].state != state { outgoing[index].state = state }
        } else {
            outgoing.remove(at: index)
        }
    }

    private var remindDecision: ActionAvailability {
        if !environment.status.safeMode.allowsMailChanges { return .disabled(.safeMode) }
        if environment.commands == nil {
            return .disabled(.unavailable(environment.actions.descriptor(.remind)?.title ?? String(localized: "Remind me")))
        }
        return .enabled
    }

    public func remindButton(for session: ComposeSession) -> ReaderActions.Availability? {
        guard let descriptor = environment.actions.descriptor(.remind) else { return nil }
        return ReaderActions.availability(descriptor, decided: remindDecision)
    }

    public func remindTitle(_ session: ComposeSession) -> String {
        guard let reminder = session.pendingReminder else { return String(localized: "Remind me") }
        let when = formatSendAt(reminder.dueAt)
        return reminder.kind == .ifNoReply ? String(localized: "Remind me \(when) if no reply")
                                           : String(localized: "Remind me \(when)")
    }

    @discardableResult
    public func remind(from session: ComposeSession) -> Bool {
        guard environment.actions.descriptor(.remind) != nil else { return false }
        if case .disabled(let reason) = remindDecision {
            environment.actions.refuse(.remind, reason)
            return reason.announces
        }
        environment.overlays.presentDraftReminder(thread: session.thread, current: session.pendingReminder) {
            [weak session] choice in
            session?.pendingReminder = choice
        }
        return true
    }

    func setPendingReminder(of session: ComposeSession, draft key: DraftKey) async {
        guard let reminder = session.pendingReminder else { return }
        session.pendingReminder = nil
        defer { forgetSendReminder(key) }
        var conversation = session.thread ?? session.draftThread
        if conversation == nil { conversation = try? await environment.data.sentConversation(key) }
        guard let thread = conversation, let actions = environment.actions.threadActions else {
            environment.notices.post(String(localized: "Sent. The reminder wasn't set: find the message in Sent and press ⇧H."),
                                     style: .error)
            return
        }
        await actions.remind(thread, at: reminder.dueAt, kind: reminder.kind, host: environment.router)?.value
    }

    func setPendingReminderOnSchedule(_ session: ComposeSession) {
        guard let reminder = session.pendingReminder else { return }
        session.pendingReminder = nil
        guard let thread = session.thread ?? session.draftThread, let actions = environment.actions.threadActions else {
            environment.notices.post(String(localized: "Scheduled. Set its reminder once it has gone out: find it in Sent and press ⇧H."),
                                     style: .info, duration: NoticeCenter.infoDuration)
            return
        }
        actions.remind(thread, at: reminder.dueAt, kind: reminder.kind, host: environment.router)
    }
}
