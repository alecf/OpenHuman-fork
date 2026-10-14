import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

public struct ReviewTarget: Hashable, Sendable {
    public let account: AccountID?
    public let draftID: String

    public init(account: AccountID?, draftID: String) {
        self.account = account
        self.draftID = draftID
    }
}

public struct ReviewContext: Equatable, Sendable {
    public let subject: String
    public let recent: [MessageSummary]
    public let olderCount: Int
    public let participants: Set<String>

    public init(subject: String, recent: [MessageSummary], olderCount: Int, participants: Set<String>) {
        self.subject = subject
        self.recent = recent
        self.olderCount = olderCount
        self.participants = participants
    }
}

@MainActor @Observable
public final class ReviewQueueModel {
    public enum Source: Equatable, Sendable {
        case closed
        case pending(AccountID)
        case link([ReviewTarget])
    }

    public enum RowState: Equatable, Sendable {
        case loading, ready
        case notFound
        case noLongerDraft
        case accountNotSetUp
    }

    public enum Outcome: Equatable, Sendable { case sent, kept, discarded }

    public struct Row: Identifiable, Equatable, Sendable {
        public let id: String
        public let target: ReviewTarget
        public var state: RowState
        public var draft: DraftSummary?
        public var outcome: Outcome?

        public var isActionable: Bool { state == .ready && draft != nil && outcome == nil }
    }

    public struct Counts: Equatable, Sendable {
        public var sent = 0, kept = 0, discarded = 0
    }

    public private(set) var source: Source = .closed
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var counts = Counts()
    public private(set) var isFinished = false
    public private(set) var context: ReviewContext?

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored public var timing: ComposeTiming
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var contextFor: String?
    @ObservationIgnored private var cursorID: String?
    @ObservationIgnored var pendingDiscards: [String: PendingReviewDiscard] = [:]
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored lazy var undoer = ReviewUndoer(model: self)

    public init(environment: AppEnvironment, timing: ComposeTiming = ComposeTiming()) {
        self.environment = environment
        self.timing = timing
    }

    isolated deinit {
        for task in observers + tasks { task.cancel() }
        contextTask?.cancel()
    }

    public var isOpen: Bool { source != .closed }

    public var summary: String {
        String(localized: "Sent \(counts.sent) · Kept \(counts.kept) · Discarded \(counts.discarded)")
    }

    public func locationChanged(_ location: MailLocation?, account: AccountID?) {
        switch location {
        case .reviewQueue(nil)?:
            guard let account else { return close() }
            if source != .pending(account) { showPending(account: account) }
        case .reviewQueue(.some)?:
            break
        default:
            if isOpen { close() }
        }
    }

    public func showPending(account: AccountID) {
        reset(to: .pending(account))
        let data = environment.data
        observe {
            do {
                for try await drafts in data.reviewQueue(account) {
                    self.applyPending(drafts)
                }
            } catch {}
        }
    }

    public func showLink(_ targets: [ReviewTarget]) {
        reset(to: .link(targets))
        rows = targets.enumerated().map { index, target in
            Row(id: Self.rowID(target, index), target: target, state: target.account == nil ? .accountNotSetUp : .loading,
                draft: nil, outcome: nil)
        }
        for (index, target) in targets.enumerated() where target.account != nil {
            observe { await self.follow(target, rowID: Self.rowID(target, index)) }
        }
        refreshCursor()
    }

    public func close() {
        guard isOpen else { return }
        let waiting = pendingDiscards.keys
        for id in Array(waiting) { track(Task { await self.finishDiscard(id) }) }
        reset(to: .closed)
    }

    private func reset(to next: Source) {
        for task in observers { task.cancel() }
        observers = []
        contextTask?.cancel()
        source = next
        rows = []
        cursor = 0
        cursorID = nil
        counts = Counts()
        isFinished = false
        context = nil
        contextFor = nil
        hidden = []
    }

    private func observe(_ body: @escaping @MainActor () async -> Void) {
        observers.append(Task { await body() })
    }

    static func rowID(_ target: ReviewTarget, _ index: Int) -> String { "\(index):\(target.draftID)" }

    private func applyPending(_ drafts: [DraftSummary]) {
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = drafts.filter { !hidden.contains($0.id.rawValue) }.map { draft in
            Row(id: draft.id.rawValue, target: ReviewTarget(account: draft.account, draftID: draft.id.rawValue),
                state: Self.state(of: draft), draft: draft, outcome: previous[draft.id.rawValue]?.outcome)
        }
        refreshCursor()
    }

    private static func state(of draft: DraftSummary) -> RowState {
        switch draft.status {
        case .sent, .sending, .discarded: .noLongerDraft
        default: .ready
        }
    }

    private func follow(_ target: ReviewTarget, rowID: String) async {
        guard let account = target.account else { return }
        guard environment.router.accounts.isEmpty || environment.router.accounts.contains(where: { $0.id == account }) else {
            update(rowID) { $0.state = .accountNotSetUp }
            return
        }
        let data = environment.data
        var key = DraftKey(target.draftID)
        let local = await ComposeManager.first(data.draft(key)) ?? nil
        if local == nil, let commands = environment.commands,
           let fetched = try? await commands.fetchDraftNow(account, gmailDraftID: GmailDraftID(target.draftID)) {
            key = fetched
        }
        var hadDraft = false
        do {
            for try await draft in data.draft(key) {
                guard !Task.isCancelled else { return }
                if let draft, draft.account == account {
                    hadDraft = true
                    update(rowID) {
                        $0.draft = draft
                        $0.state = Self.state(of: draft)
                    }
                } else {
                    update(rowID) {
                        $0.draft = nil
                        $0.state = hadDraft ? .noLongerDraft : .notFound
                    }
                }
            }
        } catch {
            update(rowID) { if $0.draft == nil { $0.state = .notFound } }
        }
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
        refreshCursor()
    }

    public var current: Row? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    private func refreshCursor() {
        if let cursorID, let index = rows.firstIndex(where: { $0.id == cursorID }) {
            cursor = index
        } else {
            cursor = min(cursor, max(0, rows.count - 1))
            cursorID = rows.indices.contains(cursor) ? rows[cursor].id : nil
        }
        if case .pending = source, rows.isEmpty, counts.sent + counts.kept + counts.discarded > 0 { isFinished = true }
        loadContextIfNeeded()
    }

    @discardableResult
    public func next() -> Bool { move(to: cursor + 1) }

    @discardableResult
    public func previous() -> Bool { move(to: cursor - 1) }

    @discardableResult
    public func skip() -> Bool {
        guard current != nil else { return false }
        if !move(to: cursor + 1) { isFinished = true }
        return true
    }

    private func move(to index: Int) -> Bool {
        guard rows.indices.contains(index) else { return false }
        cursor = index
        cursorID = rows[index].id
        isFinished = false
        loadContextIfNeeded()
        return true
    }

    private func advance(after id: String, _ outcome: Outcome) {
        switch outcome {
        case .sent: counts.sent += 1
        case .kept: counts.kept += 1
        case .discarded: counts.discarded += 1
        }
        switch source {
        case .pending:
            hidden.insert(id)
            rows.removeAll { $0.id == id }
            refreshCursor()
            if rows.isEmpty { isFinished = true }
        case .link:
            update(id) { $0.outcome = outcome }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                if !move(to: index + 1) { isFinished = true }
            }
        case .closed:
            break
        }
    }

    public var changes: ReviewChanges? {
        guard let draft = current?.draft, let snapshot = draft.agentSnapshot else { return nil }
        return ReviewDiff.changes(from: snapshot, to: draft.fields)
    }

    public var conflictChanges: ReviewChanges? {
        guard let draft = current?.draft, draft.hasRemoteConflict, let snapshot = draft.agentSnapshot else { return nil }
        return ReviewDiff.changes(from: draft.fields, to: snapshot)
    }

    public var recipientFlags: ReviewRecipientFlags? {
        guard let draft = current?.draft,
              let account = environment.router.accounts.first(where: { $0.id == draft.account })?.account else { return nil }
        var known = Set(context?.participants ?? [])
        if draft.thread == nil { known = [] }
        known.formUnion(account.myAddresses.map { $0.lowercased() })
        return ReviewRecipientFlags.compute(fields: draft.fields, account: account.email, known: known)
    }

    private func loadContextIfNeeded() {
        guard let row = current, let thread = row.draft?.thread else {
            context = nil
            contextFor = nil
            return
        }
        guard contextFor != row.id else { return }
        contextFor = row.id
        context = nil
        contextTask?.cancel()
        let data = environment.data
        let id = row.id
        contextTask = Task { [weak self] in
            let detail = await ComposeManager.first(data.threadDetail(thread)) ?? nil
            guard let self, !Task.isCancelled, self.contextFor == id, let detail else { return }
            var people = Set<String>()
            for message in detail.messages {
                for address in ([message.from].compactMap { $0 } + message.to + message.cc + message.bcc) {
                    people.insert(address.email.lowercased())
                }
            }
            self.context = ReviewContext(subject: detail.subject, recent: Array(detail.messages.suffix(2)),
                                         olderCount: max(0, detail.messages.count - 2), participants: people)
        }
    }

    private var commands: (any MailCommanding)? {
        environment.status.safeMode.allowsMailChanges ? environment.commands : nil
    }

    @discardableResult
    public func keep() -> Task<Void, Never>? {
        guard let row = current, row.isActionable, let key = row.draft?.id, let commands else { return nil }
        advance(after: row.id, .kept)
        return track(Task {
            do { try await commands.setReviewState(key, .approved) } catch { self.failed(error) }
        })
    }

    @discardableResult
    public func discard() -> Task<Void, Never>? {
        guard let row = current, row.isActionable, let draft = row.draft, let commands else { return nil }
        let key = draft.id
        pendingDiscards[row.id] = PendingReviewDiscard(draft: key, row: row)
        advance(after: row.id, .discarded)
        let id = row.id
        let window = timing.discardWindow
        let sleep = timing.sleep
        return track(Task {
            do { try await commands.setReviewState(key, .rejected) } catch {
                self.pendingDiscards[id] = nil
                self.failed(error)
                return
            }
            self.pushUndo(for: id, key: key)
            self.track(Task {
                try? await sleep(window)
                await self.finishDiscard(id)
            })
        })
    }

    private func pushUndo(for id: String, key: DraftKey) {
        guard let undo = environment.undo,
              let payload = try? JSONEncoder().encode(ReviewUndoAction(row: id, draft: key.rawValue)) else { return }
        undo.push(UndoCoordinator.Entry(title: "Discarded draft", token: UndoToken(payload: payload),
                                        expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(timing.discardWindow)),
                                        undoer: undoer))
    }

    func finishDiscard(_ id: String) async {
        guard let pending = pendingDiscards.removeValue(forKey: id), let commands else { return }
        try? await commands.discardDraft(pending.draft)
    }

    func undoDiscard(row id: String) async throws {
        guard let pending = pendingDiscards.removeValue(forKey: id), let commands = environment.commands else { return }
        try await commands.setReviewState(pending.draft, .pending)
        counts.discarded = max(0, counts.discarded - 1)
        isFinished = false
        switch source {
        case .pending:
            hidden.remove(id)
            var restored = pending.row
            restored.outcome = nil
            if !rows.contains(where: { $0.id == id }) { rows.append(restored) }
        case .link:
            update(id) { $0.outcome = nil }
        case .closed:
            break
        }
    }

    public var hasQuitWork: Bool { !pendingDiscards.isEmpty }

    public func prepareForQuit() async {
        for id in Array(pendingDiscards.keys) { await finishDiscard(id) }
    }

    @discardableResult
    public func edit() -> Task<Void, Never>? {
        guard let row = current, row.isActionable, let key = row.draft?.id else { return nil }
        let manager = environment.compose
        return track(Task { _ = await manager.openDraft(key).value })
    }

    @discardableResult
    public func send() -> Task<Void, Never>? {
        guard let row = current, row.isActionable, let key = row.draft?.id else { return nil }
        let manager = environment.compose
        return track(Task {
            guard let session = await manager.openDraft(key).value else { return }
            let actions = environment.actions
            guard actions.perform(.send, source: .keyboard, host: environment.router, context: session.actionContext()) else { return }
            await actions.lastTask?.value
            if manager.isSending(session) { self.advance(after: row.id, .sent) }
        })
    }

    @discardableResult
    public func resolveConflict(_ choice: DraftConflictResolution) -> Task<Void, Never>? {
        guard let draft = current?.draft, draft.hasRemoteConflict, let commands else { return nil }
        return track(Task {
            do { try await commands.resolveDraftConflict(draft.id, choice) } catch { self.failed(error) }
        })
    }

    private func failed(_ error: Error) {
        let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
        environment.notices.post(String(localized: "Couldn't update the draft. \(detail)"), style: .error)
    }

    @discardableResult
    private func track(_ task: Task<Void, Never>) -> Task<Void, Never> {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
        return task
    }

    public func settle() async {
        var index = 0
        while index < tasks.count {
            await tasks[index].value
            index += 1
        }
    }
}

struct PendingReviewDiscard {
    let draft: DraftKey
    let row: ReviewQueueModel.Row
}

struct ReviewUndoAction: Codable, Sendable {
    let row: String
    let draft: String
}

@MainActor
final class ReviewUndoer: MailUndoing {
    private weak var model: ReviewQueueModel?

    init(model: ReviewQueueModel) {
        self.model = model
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        let action = try JSONDecoder().decode(ReviewUndoAction.self, from: token.payload)
        try await model?.undoDiscard(row: action.row)
        return nil
    }
}

extension ComposeManager {
    func isSending(_ session: ComposeSession) -> Bool { held[session.id] != nil }
}
