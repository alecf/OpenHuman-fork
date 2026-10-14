import Foundation
import MailModel
import Observation

@MainActor @Observable
public final class UndoCoordinator {
    public struct Entry: Identifiable {
        public let id: UUID
        public var title: LocalizedStringResource
        public var token: UndoToken
        public var expiresAt: Date?
        public var threads: [ThreadKey]
        public var undoer: (any MailUndoing)?
        public var reopens: Reopen?
        public var secondary: NoticeCenter.Choice?

        public struct Reopen: Sendable, Equatable {
            public var thread: ThreadKey
            public var shown: ThreadKey?

            public init(thread: ThreadKey, shown: ThreadKey?) {
                self.thread = thread
                self.shown = shown
            }
        }

        public init(id: UUID = UUID(), title: LocalizedStringResource, token: UndoToken, expiresAt: Date? = nil,
                    threads: [ThreadKey] = [], undoer: (any MailUndoing)? = nil, reopens: Reopen? = nil,
                    secondary: NoticeCenter.Choice? = nil) {
            self.id = id
            self.title = title
            self.token = token
            self.expiresAt = expiresAt
            self.threads = threads
            self.undoer = undoer
            self.reopens = reopens
            self.secondary = secondary
        }
    }

    public static let maxEntries = 20

    public private(set) var stack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public private(set) var isWorking = false
    @ObservationIgnored public var onUndone: (@MainActor (Entry) -> Void)?

    @ObservationIgnored private let commands: any MailUndoing
    @ObservationIgnored private let notices: NoticeCenter?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var toastIDs: [Entry.ID: Toast.ID] = [:]
    @ObservationIgnored private var performing = 0
    @ObservationIgnored private var waitingForPerform: [CheckedContinuation<Void, Never>] = []

    public init(commands: any MailUndoing, notices: NoticeCenter?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.commands = commands
        self.notices = notices
        self.now = now
    }

    public var canUndo: Bool { !isWorking && stack.contains { isLive($0) } }
    public var canRedo: Bool { !isWorking && !redoStack.isEmpty }

    public func push(_ entry: Entry) {
        redoStack.removeAll()
        record(entry)
    }

    @discardableResult
    public func perform(_ title: LocalizedStringResource, threads: [ThreadKey] = [], via undoer: (any MailUndoing)? = nil,
                        reopens: Entry.Reopen? = nil, _ command: () async throws -> UndoToken) async throws -> Entry {
        performing += 1
        defer {
            performing -= 1
            if performing == 0 {
                let waiting = waitingForPerform
                waitingForPerform = []
                for continuation in waiting { continuation.resume() }
            }
        }
        let entry = Entry(title: title, token: try await command(), threads: threads, undoer: undoer, reopens: reopens)
        if !entry.token.changesNothing { push(entry) }
        return entry
    }

    public var nextUndo: Entry? { stack.last { isLive($0) } }

    public func undoLast() async {
        guard !isWorking else { return }
        if performing > 0 {
            let newest = stack.last?.id
            await withCheckedContinuation { waitingForPerform.append($0) }
            guard !isWorking, stack.last?.id != newest else { return }
        }
        stack.removeAll { !isLive($0) }
        guard let entry = stack.last else { return }
        await undo(entry)
    }

    public func undo(entryID: Entry.ID) async {
        guard !isWorking, let entry = stack.first(where: { $0.id == entryID }), isLive(entry) else { return }
        await undo(entry)
    }

    public func redoLast() async {
        guard !isWorking, let entry = redoStack.popLast() else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            if let token = try await (entry.undoer ?? commands).undo(entry.token) {
                record(Entry(title: entry.title, token: token, threads: entry.threads, undoer: entry.undoer))
            }
        } catch {
            redoStack.append(entry)
            notices?.post(String(localized: "Couldn't redo"), style: .error)
        }
    }

    private func undo(_ entry: Entry) async {
        isWorking = true
        defer { isWorking = false }
        stack.removeAll { $0.id == entry.id }
        if let toast = toastIDs.removeValue(forKey: entry.id) { notices?.dismiss(toast) }
        do {
            if let redo = try await (entry.undoer ?? commands).undo(entry.token) {
                redoStack.append(Entry(title: entry.title, token: redo, threads: entry.threads, undoer: entry.undoer))
            }
            onUndone?(entry)
        } catch {
            stack.append(entry)
            notices?.post(String(localized: "Couldn't undo \(String(localized: entry.title))"), style: .error)
        }
    }

    private func record(_ entry: Entry) {
        stack.append(entry)
        if stack.count > Self.maxEntries {
            let dropped = stack.removeFirst()
            toastIDs[dropped.id] = nil
        }
        guard let notices else { return }
        let id = entry.id
        toastIDs[id] = notices.post(String(localized: entry.title), style: .undo,
                                    actionTitle: String(localized: "Undo"), shortcut: "⌘Z",
                                    duration: toastDuration(entry), holdsWindow: entry.expiresAt != nil,
                                    secondary: entry.secondary) { [weak self] in
            await self?.undo(entryID: id)
        }
    }

    private func toastDuration(_ entry: Entry) -> Duration {
        guard let expiresAt = entry.expiresAt else { return NoticeCenter.toastDuration }
        return .milliseconds(Int((max(0, expiresAt.timeIntervalSince(now())) * 1000).rounded()))
    }

    private func isLive(_ entry: Entry) -> Bool {
        entry.expiresAt.map { $0 > now() } ?? true
    }
}
