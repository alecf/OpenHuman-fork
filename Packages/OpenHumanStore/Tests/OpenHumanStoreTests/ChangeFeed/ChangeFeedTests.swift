import Darwin
import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Synchronization
import Testing
@testable import OpenHumanStore
import notify

@Suite struct WriteWrapperTests {
    @Test func requeueingNothingStaleIsNotAWrite() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let start = try changeFeedSeq(store)
        for _ in 0..<5 {
            #expect(try store.requeueStaleInFlight(account: account, claimedBefore: Date().addingTimeInterval(60)) == 0)
        }
        #expect(try changeFeedSeq(store) == start)
    }

    @Test func everyWriteBumpsTheWritersRowByExactlyOne() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = try changeFeedSeq(store)
        try store.write { try $0.execute(sql: "UPDATE schema_info SET created_by_version = 'x'") }
        #expect(try changeFeedSeq(store) == start + 1)
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        #expect(try changeFeedSeq(store) == start + 2)
        _ = try store.accounts()
        #expect(try changeFeedSeq(store) == start + 2)
        let row = try store.read { try Row.fetchOne($0, sql: "SELECT kind, pid FROM change_feed WHERE writer_id = ?", arguments: [store.writerID]) }
        #expect(row?["kind"] as String? == "app")
        #expect(row?["pid"] as Int? == Int(ProcessInfo.processInfo.processIdentifier))
    }

    @Test func aThrowingWriteRollsBackIncludingTheBump() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = try changeFeedSeq(store)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try store.write { db in
                try db.execute(sql: "UPDATE schema_info SET created_by_version = 'changed'")
                throw Boom()
            }
        }
        #expect(try changeFeedSeq(store) == start)
        #expect(try store.read { try String.fetchOne($0, sql: "SELECT created_by_version FROM schema_info") } == "0.0.0-test")
    }

    @Test func readOnlyStoresRejectWritesWithoutTouchingTheFeed() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.close()
        let (ro, _) = try openTemp(readOnly: true, dir: dir)
        #expect(throws: StoreError.readOnly) { try ro.write { _ in } }
        #expect(throws: StoreError.readOnly) { try ro.bumpObservationPulse() }
        #expect(try ro.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_feed WHERE writer_id = ?", arguments: [ro.writerID]) } == 0)
    }

    @Test func pulseWritesDoNotBumpTheFeed() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let feed = try changeFeedSeq(store)
        let pulse = try pulseSeq(store)
        try store.bumpObservationPulse()
        #expect(try pulseSeq(store) == pulse + 1)
        #expect(try changeFeedSeq(store) == feed)
    }

    @Test func staleFeedRowsAreDeletedOnOpen() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = Int64(86_400_000)
        try store.write { db in
            try db.execute(sql: "INSERT INTO change_feed (writer_id, pid, kind, seq, updated_at) VALUES ('old', 1, 'cli', 5, ?)", arguments: [nowMillis() - day - 1000])
            try db.execute(sql: "INSERT INTO change_feed (writer_id, pid, kind, seq, updated_at) VALUES ('recent', 1, 'cli', 5, ?)", arguments: [nowMillis() - day / 2])
        }
        try store.close()
        let (again, _) = try openTemp(dir: dir)
        let ids = try again.read { try String.fetchAll($0, sql: "SELECT writer_id FROM change_feed") }
        #expect(ids.contains("recent") && !ids.contains("old"))
    }

    @Test func inMemoryStoresHaveNoChangeFeedRow() throws {
        let store = try MailStore.openInMemoryForTesting()
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_feed") } == 0)
    }

    @Test func noSourceFileOutsideStoreCoreOpensAWriteTransaction() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if url.lastPathComponent == "StoreCore.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in ["writer.write", "writer.writeWithoutTransaction", "pool.write", "queue.write", ".writeWithoutTransaction"] {
                if text.contains(pattern), !["main.swift", "StoreCore.swift", "ExternalChangeMonitor.swift"].contains(url.lastPathComponent),
                   !text.contains("// write-path-exception") {
                    offenders.append("\(url.lastPathComponent): \(pattern)")
                }
            }
        }
        offenders.removeAll { $0.hasPrefix("MailStore+Maintenance.swift") }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

@Suite struct ExternalChangeTests {
    @Test(.timeLimit(.minutes(1))) func aWriteInAnotherStoreWakesTheObserver() async throws {
        let (a, dir) = try openTemp(kind: .app, observe: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (b, _) = try openTemp(kind: .cli, dir: dir)
        let aFeed = try changeFeedSeq(a)
        let accounts = Collector(a.observeAccounts())
        defer { accounts.stop() }
        try #require(await accounts.waitForCount(1))
        _ = try b.addAccount(email: "cli@example.com", displayName: nil, scopes: [])
        #expect(await accounts.wait { $0.last?.map(\.email) == ["cli@example.com"] })
        #expect(try changeFeedSeq(a) == aFeed, "a pulse must not bump the observer's own feed row")
        try a.close()
    }

    @Test func ownWritesDoNotPulseTheOwnMonitor() throws {
        let (a, dir) = try openTemp(kind: .app, observe: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let monitor = try #require(a.runtime.monitor)
        let before = try pulseSeq(a)
        for i in 0..<3 { _ = try a.addAccount(email: "a\(i)@example.com", displayName: nil, scopes: []) }
        #expect(monitor.checkNow() == false, "the store's own feed row is not another writer's change")
        #expect(try pulseSeq(a) == before)
        try a.close()
    }

    @Test func monitorCompareLogicPulsesOnChangedSeqOrNewWriterOnly() {
        nonisolated(unsafe) var others: [String: Int64] = ["w1": 5]
        nonisolated(unsafe) var pulses = 0
        let monitor = ExternalChangeMonitor(notificationName: uniqueNotificationName(), readOthers: { others },
                                            pulse: { pulses += 1 })
        monitor.start(poll: false)
        #expect(monitor.checkNow() == false)
        others["w1"] = 6
        #expect(monitor.checkNow() && pulses == 1)
        #expect(monitor.checkNow() == false)
        others["w2"] = 0
        #expect(monitor.checkNow() && pulses == 2)
        others["w2"] = nil
        #expect(monitor.checkNow() == false && pulses == 2)
        monitor.stop()
        others["w1"] = 7
        #expect(monitor.checkNow() == false, "stopped monitors do nothing")
    }

    @Test func theFallbackPollIsSlowAndFollowsActivation() {
        let policy = ExternalChangeMonitor.PollPolicy.standard
        #expect(policy.active >= 30 && policy.inactive >= policy.active)
        #expect(policy.leewayFraction >= 0.1)
        #expect(policy.leeway(active: true) == .milliseconds(3_000))
        let monitor = ExternalChangeMonitor(notificationName: uniqueNotificationName(), readOthers: { [:] }, pulse: {})
        #expect(monitor.currentPollInterval == nil)
        monitor.start(active: true)
        #expect(monitor.currentPollInterval == 30)
        monitor.setActive(true)
        #expect(monitor.currentPollInterval == 30)
        monitor.setActive(false)
        #expect(monitor.currentPollInterval == 60)
        monitor.setActive(true)
        #expect(monitor.currentPollInterval == 30)
        monitor.stop()
        #expect(monitor.currentPollInterval == nil)
    }

    @Test func theStoreForwardsAppActivationToTheMonitor() throws {
        let (store, dir) = try openTemp(kind: .app, observe: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let monitor = try #require(store.runtime.monitor)
        #expect(monitor.currentPollInterval == 30)
        store.setExternalChangePollActive(false)
        #expect(monitor.currentPollInterval == 60)
        store.setExternalChangePollActive(true)
        #expect(monitor.currentPollInterval == 30)
        try store.close()
    }

    @Test func aFailedPulseIsRetriedOnTheNextCheck() {
        struct Busy: Error {}
        nonisolated(unsafe) var others: [String: Int64] = [:]
        nonisolated(unsafe) var failing = true
        nonisolated(unsafe) var pulses = 0
        let monitor = ExternalChangeMonitor(notificationName: uniqueNotificationName(), readOthers: { others }, pulse: {
            if failing { throw Busy() }
            pulses += 1
        })
        monitor.start(poll: false)
        others["w1"] = 1
        #expect(monitor.checkNow() == false)
        failing = false
        #expect(monitor.checkNow() && pulses == 1)
        monitor.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aNotificationCheckAndCheckNowPulseOneChangeOnce() async throws {
        struct Busy: Error {}
        let name = uniqueNotificationName()
        let others = Mutex<[String: Int64]>([:])
        let failing = Mutex(true)
        let pulses = Mutex(0)
        let (pulsed, pulse) = AsyncStream<Void>.makeStream()
        let monitor = ExternalChangeMonitor(notificationName: name, readOthers: { others.withLock { $0 } }, pulse: {
            if failing.withLock({ $0 }) { throw Busy() }
            pulses.withLock { $0 += 1 }
            pulse.yield()
        })
        monitor.start(poll: false)
        others.withLock { $0["w1"] = 1 }
        #expect(monitor.checkNow() == false)
        failing.withLock { $0 = false }
        notify_post(name)
        for await _ in pulsed { break }
        #expect(monitor.checkNow() == false, "the change was already pulsed")
        #expect(pulses.withLock { $0 } == 1)
        monitor.stop()
    }

    @Test func writesPostTheDarwinNotification() throws {
        let name = uniqueNotificationName()
        let (store, dir) = try openTemp(kind: .cli, notificationName: name)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.runtime.notificationName == name)
        _ = try store.addAccount(email: "n@example.com", displayName: nil, scopes: [])
        #expect(store.runtime.postCount >= 1)
    }

    @Test func theDefaultNotificationNameIsTheSharedConstant() throws {
        let options = StoreOptions(location: StoreLocation(directory: tempDirectory()), processKind: .test,
                                   appVersion: "0.0.0-test")
        #expect(options.changeNotificationName == OHIdentifiers.storeChangedNotification)
        #expect(StoreRuntime().notificationName == OHIdentifiers.storeChangedNotification)
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.runtime.notificationName == OHIdentifiers.storeChangedNotification)
    }

    @Test func eachStorePostsOnItsOwnNameOnly() throws {
        let nameA = uniqueNotificationName(), nameB = uniqueNotificationName()
        let (a, dirA) = try openTemp(kind: .cli, notificationName: nameA)
        let (b, dirB) = try openTemp(kind: .cli, notificationName: nameB)
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }
        #expect(a.runtime.notificationName == nameA && b.runtime.notificationName == nameB)
        let postsA = a.runtime.postCount, postsB = b.runtime.postCount
        _ = try a.addAccount(email: "a@example.com", displayName: nil, scopes: [])
        try a.close()
        #expect(a.runtime.postCount > postsA)
        #expect(b.runtime.postCount == postsB, "a write in store A posts nothing for store B")
        try b.close()

        let posted = PostRecorder()
        let runtime = posted.runtime(nameA)
        runtime.scheduleChangePost()
        #expect(posted.names == [nameA], "a runtime posts on its own name")
    }

    @Test func theFirstPostIsImmediateAndABurstSharesOneTrailingPost() {
        let posted = PostRecorder()
        let runtime = posted.runtime("burst")
        runtime.scheduleChangePost()
        #expect(posted.names == ["burst"], "the first write after a quiet period posts at once")
        posted.advance(.milliseconds(10))
        for _ in 0..<29 { runtime.scheduleChangePost() }
        #expect(runtime.postCount == 1 && runtime.hasPendingPost)
        #expect(posted.deferred == [.milliseconds(40)], "one trailing post at the end of the window")
        posted.advance(.milliseconds(40))
        posted.runDeferred()
        #expect(runtime.postCount == 2 && !runtime.hasPendingPost)
        posted.advance(.milliseconds(50))
        runtime.scheduleChangePost()
        #expect(runtime.postCount == 3, "after a quiet window the next write posts at once again")
        #expect(posted.names == Array(repeating: "burst", count: 3))
    }

    @Test func closeFlushesTheTrailingPostOnce() throws {
        let posted = PostRecorder()
        let runtime = posted.runtime("flush")
        runtime.scheduleChangePost()
        runtime.scheduleChangePost()
        #expect(runtime.postCount == 1 && runtime.hasPendingPost)
        runtime.flushPendingPost()
        #expect(runtime.postCount == 2 && !runtime.hasPendingPost)
        posted.runDeferred()
        #expect(runtime.postCount == 2, "the window ending later posts nothing more")
        runtime.flushPendingPost()
        #expect(runtime.postCount == 2, "nothing waiting, nothing posted")

        let (store, dir) = try openTemp(kind: .cli, notificationName: uniqueNotificationName())
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = store.runtime.postCount
        _ = try store.addAccount(email: "one@example.com", displayName: nil, scopes: [])
        store.runtime.scheduleChangePost()
        try store.close()
        #expect(!store.runtime.hasPendingPost, "a closing store posts what was waiting")
        #expect(store.runtime.postCount > before)
    }

    @Test(.timeLimit(.minutes(1))) func aWriteFromAnotherProcessWakesTheObserver() async throws {
        let (a, dir) = try openTemp(kind: .app, observe: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let accounts = Collector(a.observeAccounts())
        defer { accounts.stop() }
        try #require(await accounts.waitForCount(1))
        let helper = try HelperProcess(["--home", dir.path, "bump"])
        #expect(helper.waitFor("done"))
        #expect(helper.finish() == 0)
        #expect(await accounts.wait { $0.last?.count == 1 }, "the helper's account reaches this process's observation")
        let kinds = try a.read { try String.fetchAll($0, sql: "SELECT kind FROM change_feed ORDER BY kind") }
        #expect(kinds == ["app", "cli"])
        try a.close()
    }

    @Test func aHeldWriteLockInAnotherProcessMakesStoreWritesWaitThenSucceed() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = try HelperProcess(["--home", dir.path, "hold-write", "1"])
        #expect(helper.waitFor("ready"))
        let started = Date()
        _ = try store.addAccount(email: "waited@example.com", displayName: nil, scopes: [])
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(helper.finish() == 0)
    }

    @Test func aWriteLockHeldPastTheBusyTimeoutSurfacesAsBusy() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = try HelperProcess(["--home", dir.path, "hold-write", "7"])
        #expect(helper.waitFor("ready"))
        #expect(throws: StoreError.busy) { try store.write { try $0.execute(sql: "UPDATE schema_info SET created_by_version = 'x'") } }
        helper.process.terminate()
        _ = helper.finish()
    }

    @Test func archiveWrittenByAnotherProcessIsVisibleHere() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: account, removeMissing: false)
        _ = try store.upsertMessages([.fixture("m1", labels: ["INBOX"])], account: account, generation: 1)
        let tid = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t-m1"))).rowID.rawValue
        let helper = try HelperProcess(["write-archive", dir.path, String(tid)])
        #expect(helper.waitFor("done"), Comment(rawValue: helper.stderrText))
        #expect(helper.finish() == 0)
        let inbox = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10).items
        #expect(inbox.isEmpty)
    }
}


func uniqueNotificationName() -> String {
    OHIdentifiers.storeChangedNotification + ".test." + UUID().uuidString
}

final class PostRecorder: Sendable {
    private struct State {
        var names: [String] = []
        var deferred: [(Duration, @Sendable () -> Void)] = []
        var now = ContinuousClock.now
    }
    private let state = Mutex(State())

    var names: [String] { state.withLock { $0.names } }
    var deferred: [Duration] { state.withLock { $0.deferred.map(\.0) } }

    func runtime(_ name: String) -> StoreRuntime {
        StoreRuntime(notificationName: name,
                     post: { name in self.state.withLock { $0.names.append(name) } },
                     now: { self.state.withLock { $0.now } },
                     runLater: { delay, work in self.state.withLock { $0.deferred.append((delay, work)) } })
    }

    func advance(_ duration: Duration) { state.withLock { $0.now += duration } }

    func runDeferred() {
        let work = state.withLock { state in
            defer { state.deferred = [] }
            return state.deferred.map(\.1)
        }
        for item in work { item() }
    }
}

final class DarwinNotification: Sendable {
    private let token: Int32
    private let stream: AsyncStream<Void>

    init(_ name: String) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var token: Int32 = 0
        notify_register_dispatch(name, &token, DispatchQueue(label: "test.darwin-notification")) { _ in continuation.yield() }
        self.token = token
        self.stream = stream
    }

    func next() async {
        for await _ in stream { return }
    }

    func cancel() { notify_cancel(token) }
}
