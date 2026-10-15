import Foundation
import MailModel
import Synchronization
import Testing
@testable import MailFeatures

final class FakeUndoPort: MailUndoing {
    struct State { var done: Set<String> = []; var calls: [String] = []; var failNext = false; var nothingToUndo = false }
    let state = Mutex(State())

    func markDone(_ thread: String) -> UndoToken {
        state.withLock { _ = $0.done.insert(thread) }
        return Self.token("done:\(thread)")
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let text = String(decoding: token.payload, as: UTF8.self)
        return try state.withLock { s in
            s.calls.append(text)
            if s.failNext { s.failNext = false; throw CancellationError() }
            if s.nothingToUndo { return nil }
            let parts = text.split(separator: ":").map(String.init)
            if parts[0] == "done" {
                s.done.remove(parts[1])
                return Self.token("inbox:\(parts[1])")
            }
            s.done.insert(parts[1])
            return Self.token("done:\(parts[1])")
        }
    }

    var done: Set<String> { state.withLock { $0.done } }
    var calls: [String] { state.withLock { $0.calls } }
    static func token(_ text: String) -> UndoToken { UndoToken(payload: Data(text.utf8)) }
}

@MainActor final class Flag {
    var on = false
}

@MainActor @Suite struct UndoCoordinatorTests {
    let port = FakeUndoPort()
    let notices = NoticeCenter(autoExpire: false)

    func coordinator() -> UndoCoordinator { UndoCoordinator(commands: port, notices: notices) }

    @Test func markDonePostsAnUndoToastAndCommandZUndoesIt() async throws {
        let undo = coordinator()
        let entry = try await undo.perform("Marked done") { port.markDone("t1") }
        #expect(port.done == ["t1"])
        #expect(undo.stack.map(\.id) == [entry.id] && undo.canUndo)
        let toast = try #require(notices.toasts.first)
        #expect(toast.message == "Marked done" && toast.style == .undo)
        #expect(toast.actionTitle == "Undo" && toast.shortcut == "⌘Z")

        var restored: [UUID] = []
        undo.onUndone = { restored.append($0.id) }
        await undo.undoLast()
        #expect(port.done.isEmpty)
        #expect(undo.stack.isEmpty && undo.redoStack.count == 1)
        #expect(notices.toasts.isEmpty)
        #expect(restored == [entry.id])
    }

    @Test func redoReappliesWithTheTokenUndoReturned() async throws {
        let undo = coordinator()
        try await undo.perform("Marked done") { port.markDone("t1") }
        await undo.undoLast()
        await undo.redoLast()
        #expect(port.done == ["t1"])
        #expect(port.calls == ["done:t1", "inbox:t1"])
        #expect(undo.stack.count == 1 && undo.redoStack.isEmpty)
        await undo.undoLast()
        #expect(port.done.isEmpty)
    }

    @Test func aNewActionClearsRedo() async throws {
        let undo = coordinator()
        try await undo.perform("Marked done") { port.markDone("t1") }
        await undo.undoLast()
        try await undo.perform("Marked done") { port.markDone("t2") }
        #expect(undo.redoStack.isEmpty && !undo.canRedo)
    }

    @Test func toastUndoTargetsItsOwnEntry() async throws {
        let undo = coordinator()
        let first = try await undo.perform("Marked done") { port.markDone("t1") }
        try await undo.perform("Marked done") { port.markDone("t2") }
        #expect(notices.toasts.count == 2)
        let firstToast = try #require(notices.toasts.first)
        await notices.activate(firstToast.id)
        #expect(port.done == ["t2"])
        #expect(!undo.stack.contains { $0.id == first.id })
        #expect(notices.toasts.count == 1)
    }

    @Test func aFailedUndoStaysUndoableAndSaysSo() async throws {
        let undo = coordinator()
        try await undo.perform("Marked done") { port.markDone("t1") }
        port.state.withLock { $0.failNext = true }
        await undo.undoLast()
        #expect(port.done == ["t1"])
        #expect(undo.stack.count == 1)
        #expect(notices.toasts.last?.style == .error)
        await undo.undoLast()
        #expect(port.done.isEmpty)
    }

    @Test func nothingToUndoLeavesNoRedo() async throws {
        let undo = coordinator()
        try await undo.perform("Marked done") { port.markDone("t1") }
        port.state.withLock { $0.nothingToUndo = true }
        await undo.undoLast()
        #expect(undo.stack.isEmpty && undo.redoStack.isEmpty)
    }

    @Test func stackKeepsTheLastTwentyAndSkipsExpiredEntries() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_790_000_000))
        let undo = UndoCoordinator(commands: port, notices: nil, now: { clock.withLock { $0 } })
        for n in 0..<25 { undo.push(.init(title: "Marked done", token: port.markDone("t\(n)"))) }
        #expect(undo.stack.count == 20)
        undo.push(.init(title: "Sending", token: FakeUndoPort.token("done:x"),
                        expiresAt: clock.withLock { $0 }.addingTimeInterval(10)))
        clock.withLock { $0 = $0.addingTimeInterval(11) }
        await undo.undoLast()
        #expect(port.calls == ["done:t24"])
    }

    @Test func aWindowedEntrysToastKeepsItsUndoUpForTheWholeWindow() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let notices = NoticeCenter(now: { start }, autoExpire: false)
        let undo = UndoCoordinator(commands: port, notices: notices, now: { start })
        undo.push(.init(title: "Reply sent.", token: FakeUndoPort.token("done:x"), expiresAt: start.addingTimeInterval(30)))
        undo.push(.init(title: "Marked done", token: port.markDone("t1")))
        let toasts = notices.toasts
        #expect(toasts.map(\.message) == ["Reply sent.", "Marked done"])
        #expect(toasts.first?.expiresAt == start.addingTimeInterval(30), "the send's window, not 6 s")
        #expect(toasts.last?.expiresAt == start.addingTimeInterval(6))
        #expect(toasts.first?.actionTitle == "Undo")
    }

    @Test func commandZWhileAnActionHasNotAnsweredUndoesThatAction() async throws {
        let undo = coordinator()
        let first = try await undo.perform("Marked done") { port.markDone("t1") }
        let gate = TestGate()
        let parked = Flag()
        let action = Task {
            _ = try await undo.perform("Marked done") {
                parked.on = true
                await gate.wait()
                return port.markDone("t2")
            }
        }
        for _ in 0..<10_000 where !parked.on { await Task.yield() }
        let undoing = Task { await undo.undoLast() }
        for _ in 0..<1_000 where port.calls.isEmpty { await Task.yield() }
        gate.release()
        _ = try await action.value
        await undoing.value
        #expect(port.done == ["t1"])
        #expect(undo.stack.map(\.id) == [first.id])
    }

    @Test func commandZWhileAnActionFailsUndoesNothing() async throws {
        let undo = coordinator()
        let first = try await undo.perform("Marked done") { port.markDone("t1") }
        let gate = TestGate()
        let parked = Flag()
        let action = Task {
            _ = try await undo.perform("Marked done") {
                parked.on = true
                await gate.wait()
                throw CancellationError()
            }
        }
        for _ in 0..<10_000 where !parked.on { await Task.yield() }
        let undoing = Task { await undo.undoLast() }
        for _ in 0..<1_000 where port.calls.isEmpty { await Task.yield() }
        gate.release()
        _ = try? await action.value
        await undoing.value
        #expect(port.done == ["t1"] && port.calls.isEmpty)
        #expect(undo.stack.map(\.id) == [first.id])
    }

    @Test func theUndoToastIsUpBeforeTheWriteFinishesAndUndoesItOnceWritten() async throws {
        let undo = coordinator()
        let gate = TestGate()
        let parked = Flag()
        let action = Task {
            _ = try await undo.perform("Moved to Trash") {
                parked.on = true
                await gate.wait()
                return port.markDone("t1")
            }
        }
        for _ in 0..<10_000 where !parked.on { await Task.yield() }
        #expect(parked.on && port.done.isEmpty, "the write is still running")
        let toast = try #require(notices.toasts.first, "the toast does not wait for the write")
        let entryID = try #require(undo.stack.last?.id)
        #expect(toast.message == "Moved to Trash" && toast.actionTitle == "Undo")
        #expect(undo.canUndo)
        let undoing = Task { await notices.activate(toast.id) }
        for _ in 0..<1_000 where port.calls.isEmpty { await Task.yield() }
        #expect(port.calls.isEmpty, "Undo waits for the write it reverses")
        gate.release()
        try await action.value
        await undoing.value
        #expect(port.calls == ["done:t1"] && port.done.isEmpty)
        #expect(!undo.stack.contains { $0.id == entryID } && undo.redoStack.count == 1)
    }

    @Test func aWriteThatFailsAfterItsToastTakesTheToastAway() async throws {
        let undo = coordinator()
        let earlier = try await undo.perform("Marked done") { port.markDone("t0") }
        let gate = TestGate()
        let parked = Flag()
        let action = Task {
            _ = try await undo.perform("Moved to Trash") {
                parked.on = true
                await gate.wait()
                throw CancellationError()
            }
        }
        for _ in 0..<10_000 where !parked.on { await Task.yield() }
        #expect(notices.toasts.map(\.message) == ["Marked done", "Moved to Trash"])
        gate.release()
        _ = try? await action.value
        #expect(undo.stack.map(\.id) == [earlier.id])
        #expect(notices.toasts.map(\.message) == ["Marked done"], "the failure notice replaces it")
    }

    @Test func aFailingCommandPushesNothing() async throws {
        let undo = coordinator()
        var threw = false
        do {
            try await undo.perform("Marked done") { throw CancellationError() }
        } catch {
            threw = error is CancellationError
        }
        #expect(threw)
        #expect(undo.stack.isEmpty && notices.toasts.isEmpty)
    }
}

@MainActor @Suite struct NoticeCenterTests {
    @Test func atMostTwoToastsAndTheyExpireAfterSixSeconds() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let notices = NoticeCenter(now: { start }, autoExpire: false)
        let a = notices.post("A")
        notices.post("B")
        notices.post("C", duration: nil)
        #expect(notices.toasts.map(\.message) == ["B", "C"])
        #expect(!notices.toasts.contains { $0.id == a })
        #expect(notices.toasts.first?.expiresAt == start.addingTimeInterval(6))
        notices.expire(asOf: start.addingTimeInterval(6))
        #expect(notices.toasts.map(\.message) == ["C"])
        notices.dismiss(notices.toasts[0].id)
        #expect(notices.toasts.isEmpty)
    }

    @Test func autoExpiryRemovesTheToast() async throws {
        let notices = NoticeCenter()
        notices.post("Marked done", duration: .milliseconds(20))
        #expect(notices.toasts.count == 1)
        for _ in 0..<12_000 where !notices.toasts.isEmpty { try await Task.sleep(for: .milliseconds(10)) } // flake-ok: exercises real-time toast expiration
        #expect(notices.toasts.isEmpty)
    }

    @Test func activateRunsTheActionOnce() async {
        let notices = NoticeCenter(autoExpire: false)
        var runs = 0
        let id = notices.post("Marked done", style: .undo, actionTitle: "Undo") { runs += 1 }
        await notices.activate(id)
        await notices.activate(id)
        #expect(runs == 1 && notices.toasts.isEmpty)
    }

    @Test func aToastUnderThePointerWaitsAndThenKeepsTheResumeMinimum() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = Mutex(start)
        let notices = NoticeCenter(now: { clock.withLock { $0 } }, autoExpire: false)
        let id = notices.post("Marked done", style: .undo, actionTitle: "Undo", shortcut: "⌘Z")
        clock.withLock { $0 = start.addingTimeInterval(5.5) }
        notices.pause(id)
        #expect(notices.isPaused(id))
        notices.expire(asOf: start.addingTimeInterval(60))
        #expect(notices.toasts.map(\.id) == [id], "held while the pointer is over it")
        clock.withLock { $0 = start.addingTimeInterval(60) }
        notices.resume(id)
        #expect(!notices.isPaused(id))
        #expect(notices.toasts.first?.expiresAt == start.addingTimeInterval(61.5), "0.5 s left becomes the 1.5 s minimum")
        notices.expire(asOf: start.addingTimeInterval(61.4))
        #expect(notices.toasts.count == 1)
        notices.expire(asOf: start.addingTimeInterval(61.5))
        #expect(notices.toasts.isEmpty)
    }

    @Test func aResumedToastKeepsTheTimeItHadLeft() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let clock = Mutex(start)
        let notices = NoticeCenter(now: { clock.withLock { $0 } }, autoExpire: false)
        let id = notices.post("Moved to Trash", style: .undo, actionTitle: "Undo")
        let sticky = notices.post("Couldn't send. It's in Drafts.", style: .error, duration: nil)
        clock.withLock { $0 = start.addingTimeInterval(1) }
        notices.pause(id)
        notices.pause(sticky)
        #expect(!notices.isPaused(sticky), "a toast that stays until dismissed has no timer to hold")
        clock.withLock { $0 = start.addingTimeInterval(30) }
        notices.resume(id)
        #expect(notices.toasts.first?.expiresAt == start.addingTimeInterval(35))
    }
}
