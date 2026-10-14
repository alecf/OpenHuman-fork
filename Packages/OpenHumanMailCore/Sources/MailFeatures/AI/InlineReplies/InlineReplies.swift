import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class InlineReplies {
    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var rows: [ReplyKey: InlineReplyRow] = [:]
    @ObservationIgnored private var order: [ReplyKey] = []
    @ObservationIgnored private var judged: [ReplyKey: InlineReplyRow.Decision] = [:]
    static let capacity = 120

    init(center: AICenter) {
        self.center = center
    }

    public func row(for thread: ThreadKey, message: MessageKey) -> InlineReplyRow {
        let key = ReplyKey(thread: thread, message: message)
        order.removeAll { $0 == key }
        order.append(key)
        if let row = rows[key] { return row }
        for old in order where old.thread == thread && old.message != message {
            rows[old]?.retire()
            rows[old] = nil
        }
        order.removeAll { $0.thread == thread && $0.message != message }
        let row = InlineReplyRow(thread: thread, message: message, center: center)
        if let decision = judged.removeValue(forKey: key), let center {
            row.preset(decision, replies: decision == .needsReply ? center.quickReplies(for: thread, replyingTo: message)
                                                                  : nil)
        }
        rows[key] = row
        while order.count > Self.capacity { rows[order.removeFirst()] = nil }
        return row
    }

    public var current: InlineReplyRow? {
        guard let reader = center?.environment?.router.active?.reader, let newest = reader.messages.last?.id else {
            return nil
        }
        return rows[ReplyKey(thread: reader.thread, message: newest)]
    }

    func record(_ decision: InlineReplyRow.Decision, thread: ThreadKey, message: MessageKey) {
        let key = ReplyKey(thread: thread, message: message)
        if let row = rows[key] {
            if row.decision == .undecided {
                row.preset(decision, replies: decision == .needsReply ? center?.quickReplies(for: thread, replyingTo: message)
                                                                      : nil)
            }
            return
        }
        if judged.count >= Self.capacity, let any = judged.keys.first { judged[any] = nil }
        judged[key] = decision
    }

    func reset() {
        for row in rows.values { row.reset() }
        rows = [:]
        order = []
        judged = [:]
    }
}

@MainActor @Observable
public final class InlineReplyRow: Identifiable {
    public enum State: Equatable, Sendable {
        case undecided
        case none
        case writing
        case ready
    }

    public enum Decision: Equatable, Sendable {
        case undecided
        case needsReply
        case skipped(NeedsReplySkip)
        case notOffered
    }

    public let id = UUID()
    public let thread: ThreadKey
    public let message: MessageKey
    public private(set) var decision: Decision = .undecided
    public private(set) var replies: QuickRepliesModel?
    public private(set) var isEngaged = false
    public private(set) var isDismissed = false
    public private(set) var usedID: String?
    private var selectedID: String?

    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var evaluation: Task<Void, Never>?
    @ObservationIgnored private var accepting = false

    init(thread: ThreadKey, message: MessageKey, center: AICenter?) {
        self.thread = thread
        self.message = message
        self.center = center
    }

    isolated deinit {
        evaluation?.cancel()
    }

    public var state: State {
        if isDismissed { return .none }
        if openReply?.holdsUserText == true { return .none }
        if !items.isEmpty { return .ready }
        let ai = aiState
        return ai == .ready ? .none : ai
    }

    var aiState: State {
        guard let center, center.showsInlineReplies, !isDismissed else { return .none }
        switch decision {
        case .undecided: return .undecided
        case .skipped, .notOffered: return .none
        case .needsReply: break
        }
        guard let replies, !replies.hiddenInComposer else { return .none }
        switch replies.phase {
        case .idle, .loading: return .writing
        case .ready: return options.isEmpty ? .none : .ready
        case .failed, .unavailable: return .none
        }
    }

    public var options: [QuickReply] { Array((replies?.options ?? []).prefix(3)) }

    public var items: [ReplySuggestion] {
        let calendar = center?.environment?.schedulingIfStarted?.suggestions(for: thread, message: message) ?? []
        return ReplySuggestions.merge(scheduling: calendar, quickReplies: aiState == .ready ? options : [])
    }

    public var isWritingMore: Bool { aiState == .writing && !items.isEmpty }

    var replyIndices: [Int] {
        let items = self.items
        return items.indices.filter { items[$0].isReply }
    }

    public var replyCount: Int { replyIndices.count }

    public var selection: Int {
        let items = self.items
        if let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }), items[index].isReply {
            return index
        }
        return items.firstIndex(where: \.isReply) ?? 0
    }

    public var preview: ReplySuggestion? {
        guard state == .ready else { return nil }
        let items = self.items
        guard items.indices.contains(selection), items[selection].isReply else { return nil }
        return items[selection]
    }

    public var isSuspicious: Bool { replies?.isSuspicious ?? false }

    public var isAccepted: Bool { usedID != nil }

    public var accessibilityLabel: String {
        switch state {
        case .writing: return String(localized: "Writing suggested replies")
        case .ready: return String(localized: "Suggested replies, \(items.count) suggestions")
        case .undecided, .none: return ""
        }
    }

    public func appear() {
        if decision == .needsReply {
            request()
            return
        }
        guard decision == .undecided, evaluation == nil else { return }
        evaluation = Task { [weak self] in await self?.evaluate() }
    }

    func preset(_ decision: Decision, replies: QuickRepliesModel?) {
        guard self.decision == .undecided else { return }
        self.replies = replies
        self.decision = decision
    }

    func evaluate() async {
        guard let center, center.showsInlineReplies else {
            evaluation = nil
            return
        }
        guard await center.onDeviceStatus().available else {
            decide(.notOffered)
            return
        }
        guard let context = await center.context(for: thread, upTo: message, trigger: .automatic),
              context.messageKeys.last == message, !Task.isCancelled else {
            decide(.notOffered)
            return
        }
        if let skip = NeedsReply.skipReason(center.needsReplyFacts(for: thread, context: context)) {
            decide(.skipped(skip))
            return
        }
        replies = center.quickReplies(for: thread, replyingTo: message)
        decide(.needsReply)
        request()
    }

    private func decide(_ decision: Decision) {
        self.decision = decision
        let name = switch decision {
        case .undecided: "undecided"
        case .needsReply: "needsReply"
        case .skipped(let skip): skip.rawValue
        case .notOffered: "notOffered"
        }
        Self.log("inlineReply decided reason=\(name)")
    }

    private func request() {
        guard let replies, !isDismissed else { return }
        replies.request(trigger: .automatic)
        if replies.phase == .idle { replies.retryAutomatic() }
    }

    public func next() { step(1) }

    public func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard state == .ready else { return }
        let replies = replyIndices
        guard !replies.isEmpty else { return }
        let at = replies.firstIndex(of: selection) ?? 0
        selectedID = items[replies[(at + delta + replies.count) % replies.count]].id
        isEngaged = true
    }

    public func select(_ index: Int) {
        let items = self.items
        guard state == .ready, items.indices.contains(index) else { return }
        let item = items[index]
        guard item.isReply else {
            perform(item)
            return
        }
        let wasEngaged = isEngaged
        isEngaged = true
        if replyIsOpen {
            guard item.id != usedID || !bodyHolds(item) else { return }
            selectedID = item.id
            Task { _ = await use(item) }
            return
        }
        if index == selection, wasEngaged {
            Task { _ = await use(item) }
            return
        }
        selectedID = item.id
    }

    public func dismiss() {
        guard state == .ready || state == .writing else { return }
        isDismissed = true
        Self.log("inlineReply dismissed")
    }

    public func dismissIfEngaged() -> Bool {
        guard isEngaged, state == .ready else { return false }
        dismiss()
        return true
    }

    @discardableResult
    public func accept() async -> ComposeSession? {
        guard let item = preview else { return nil }
        return await use(item)
    }

    @discardableResult
    public func use(_ item: ReplySuggestion) async -> ComposeSession? {
        guard !accepting, item.isReply, let body = item.body, let center, let environment = center.environment else {
            return nil
        }
        if let reader = environment.router.active?.reader, reader.thread == thread,
           let newest = reader.messages.last?.id, newest != message {
            Self.log("inlineReply kept reason=notNewest")
            return nil
        }
        if bodyHolds(item), let open = openReply {
            usedID = item.id
            return open
        }
        accepting = true
        defer { accepting = false }
        let before = usedID == item.id ? nil : usedID
        usedID = item.id
        let suspicious = item.kind == .quickReply && isSuspicious
        let scheduling = item.schedulingOption.flatMap { environment.schedulingIfStarted?.replyContext($0, in: thread) }
        guard let session = await environment.compose.useSuggestion(body, thread: thread, message: message,
                                                                     auto: item.kind == .quickReply,
                                                                     scheduling: scheduling) else {
            Self.log("inlineReply kept reason=closed")
            usedID = before
            return nil
        }
        if let notice = QuickReplyInsertion.notice(for: item.quickReply(id: 0), suspicious: suspicious) {
            session.notice = notice
        }
        Self.log("inlineReply used kind=\(item.kind == .quickReply ? "ai" : "calendar")")
        return session
    }

    func retire() {
        evaluation?.cancel()
        evaluation = nil
        isDismissed = true
    }

    func reset() {
        evaluation?.cancel()
        evaluation = nil
        decision = .undecided
        replies = nil
        selectedID = nil
        usedID = nil
        isEngaged = false
    }

    private var openReply: ComposeSession? {
        center?.environment?.composeIfStarted?.sessions.last {
            $0.thread == thread && $0.isOpen && ($0.mode == .reply || $0.mode == .replyAll)
        }
    }

    private var replyIsOpen: Bool { openReply != nil }

    private func bodyHolds(_ item: ReplySuggestion) -> Bool {
        guard let body = item.body, let reply = openReply else { return false }
        return reply.suggestionInBody.map { ReplySuggestions.same($0, body) } ?? false
    }

    private func perform(_ item: ReplySuggestion) {
        guard let scheduling = center?.environment?.schedulingIfStarted else { return }
        isEngaged = true
        let thread = self.thread
        Task { _ = await scheduling.use(item, in: thread) }
    }

    private nonisolated static let logger = Log(.ai)

    nonisolated static func log(_ line: String) {
        logger.info(line)
    }
}
