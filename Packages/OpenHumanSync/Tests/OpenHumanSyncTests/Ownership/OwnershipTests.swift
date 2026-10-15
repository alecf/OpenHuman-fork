import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct OwnershipTests {
    private func identity(_ owner: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                          host: String = ProcessIdentity.localHostName) -> ProcessIdentity {
        ProcessIdentity(writerID: owner, pid: pid, host: host)
    }

    private func deadPID() async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.yield(); exited.continuation.finish() }
        try process.run()
        let pid = process.processIdentifier
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in exited.stream { return true }; return true }
            group.addTask { try? await Task.sleep(for: .seconds(30)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished { process.terminate() }
        try #require(finished, "child process did not exit within 30 s")
        return pid
    }

    @Test func acquiresRenewsAndReleases() async throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let clock = TestClock(now: currentMinute())
        let manager = OwnershipManager(store: store, identity: identity("app-1"), clock: clock)
        #expect(await manager.acquire(account))
        #expect(try store.lease(account: account)?.ownerID == "app-1")
        #expect(try store.lease(account: account)?.kind == "app")

        clock.advance(by: .seconds(15))
        #expect(await manager.tick().isEmpty)
        #expect(try store.lease(account: account)?.heartbeatAt == clock.now)

        await manager.release(account)
        #expect(try store.lease(account: account) == nil)
        #expect(await manager.tick().isEmpty)
    }

    @Test func heartbeatRenewsEveryFifteenSecondsOnTheInjectedClock() async throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let clock = TestClock(now: currentMinute())
        let manager = OwnershipManager(store: store, identity: identity("app-1"), clock: clock)
        #expect(await manager.acquire(account))
        let start = clock.now
        await manager.startHeartbeat { _, _ in }
        try await eventually("heartbeat sleeping") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(15))
        try await eventually("renewed") { try store.lease(account: account)?.heartbeatAt == start.addingTimeInterval(15) }
        await manager.stopHeartbeat()
    }

    @Test func aCrashedAppsLeaseIsTakenAtOnce() async throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let clock = TestClock(now: currentMinute())
        let dead = try await deadPID()
        _ = try store.acquireLease(account: account, ownerID: "crashed-app", kind: "app", pid: dead,
                                   host: ProcessIdentity.localHostName, now: clock.now, ttl: OwnershipManager.ttl)
        let manager = OwnershipManager(store: store, identity: identity("app-2"), clock: clock)
        #expect(await manager.acquire(account))
        #expect(try store.lease(account: account)?.ownerID == "app-2")
    }

    @Test func anExpiredLeaseIsTakenAfterFortyFiveSeconds() async throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let clock = TestClock(now: currentMinute())
        _ = try store.acquireLease(account: account, ownerID: "other-mac", kind: "app", pid: 1, host: "other-host.invalid",
                                   now: clock.now, ttl: OwnershipManager.ttl)
        let manager = OwnershipManager(store: store, identity: identity("app-2"), clock: clock)
        clock.advance(by: .seconds(30))
        #expect(!(await manager.acquire(account)))
        #expect(await manager.tick().isEmpty)
        clock.advance(by: .seconds(16))
        let changes = await manager.tick()
        #expect(changes.count == 1 && changes.first?.account == account && changes.first?.isOwner == true)
        #expect(try store.lease(account: account)?.ownerID == "app-2")
    }

    @Test func aLiveOwnerKeepsItsLeaseAndALostLeaseIsReported() async throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [GmailScope.modify])
        let clock = TestClock(now: currentMinute())
        let first = OwnershipManager(store: store, identity: identity("app-1"), clock: clock)
        let second = OwnershipManager(store: store, identity: identity("app-2"), clock: clock)
        #expect(await first.acquire(account))
        #expect(!(await second.acquire(account)))

        clock.advance(by: .seconds(46))
        #expect(await second.tick().first?.isOwner == true)
        let lost = await first.tick()
        #expect(lost.count == 1 && lost.first?.isOwner == false)
        #expect(!(await first.isOwner(account)))
    }

    @Test func theAppOwnsEveryAccountAndALocalClientOnlyReadsTheLease() async throws {
        let h = try await EngineHarness(clock: TestClock(now: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))))
        let cli = h.engine(role: .localClient, factory: .some(nil))
        await cli.start()
        #expect(try h.store.lease(account: h.account) == nil)
        #expect(OwnershipManager.liveOwner(account: h.account, store: h.store) == nil)
        var snapshot = await firstValue(cli.observeConnectivity())
        #expect(snapshot?[h.account].map { if case .offline = $0 { true } else { false } } == true)

        let app = h.engine()
        let events = EngineEvents(app)
        await app.start()
        try await h.waitForSyncs(app)
        let lease = try #require(OwnershipManager.liveOwner(account: h.account, store: h.store))
        #expect(lease.kind == "app" && lease.ownerID == h.store.writerID)
        try await eventually("ownership event") { events.ownership.contains { $0 == (h.account, true) } }
        snapshot = await firstValue(cli.observeConnectivity())
        #expect(snapshot?[h.account] == .ownedElsewhere(kind: "app", lastSyncAt: try h.store.syncStatus(account: h.account).lastSuccessAt))

        await app.stop()
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test func aSecondAppOnTheSameStoreWaitsAndTakesOverWhenTheFirstStops() async throws {
        let h = try await EngineHarness(onDisk: true)
        defer { h.cleanup() }
        let first = h.engine()
        await first.start()
        try await h.waitForSyncs(first)
        let other = try MailStore.open(StoreOptions(location: StoreLocation(directory: try #require(h.directory)),
                                                    processKind: .test, appVersion: "0.0.0-test",
                                                    changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        let second = h.engine(store: other)
        let events = EngineEvents(second)
        await second.start()
        #expect(await second.runtime(for: h.account) == nil)
        try await eventually("not-owner event") { events.ownership.contains { $0 == (h.account, false) } }

        await first.stop()
        h.clock.advance(by: OwnershipManager.heartbeatInterval)
        try await eventually("second app owns it") { await second.runtime(for: h.account) != nil }
        #expect(try h.store.lease(account: h.account)?.ownerID == other.writerID)
        await second.stop()
        try other.close()
    }

    @Test func takeoverFromALiveOwnerWhoseLeaseLapsedLeavesItsInFlightOpAlone() async throws {
        let h = try await EngineHarness(onDisk: true)
        defer { h.cleanup() }
        let a = h.engine()
        await a.start()
        try await h.waitForSyncs(a)
        await h.gmail.latency(.createDraft, .seconds(2))
        let content = DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [],
                                   subject: "Synthetic", bodyHTML: "<p>Synthetic</p>", attachments: [])
        let draft = try h.store.createDraft(account: h.account, mode: .new, replyTo: nil, content: content, origin: .user,
                                            reviewState: .none, agentNote: nil, extraHeaders: [:])
        let upload = try h.store.saveDraftRemotely(draft)
        try await eventually("A's create in flight") {
            let calls = await h.gmail.callCount(.createDraft)
            return try h.store.operation(upload)?.status == .inFlight && calls == 1
        }
        let late = TestClock(now: h.clock.now.addingTimeInterval(46))
        let storeB = try MailStore.open(StoreOptions(location: StoreLocation(directory: try #require(h.directory)),
                                                     processKind: .test, appVersion: "0.0.0-test",
                                                     changeNotificationName: "dev.openhuman.test.\(UUID().uuidString)"))
        let b = MailEngine(store: storeB, gmailFactory: h.factory, tokenStore: nil, oauthClient: nil,
                           configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test", gmail: engineGmailConfig,
                                                              clock: late, schedulers: []),
                           systemEvents: nil)
        await b.start()
        try await h.waitForSyncs(b)
        #expect(try storeB.lease(account: h.account)?.ownerID == storeB.writerID)
        #expect(try h.store.operation(upload)?.status == .inFlight)
        h.clock.advance(by: .seconds(2))
        try await eventually("the upload is done") { try h.store.operation(upload)?.status == .succeeded }
        #expect(try h.store.operation(upload)?.attempts == 0)
        #expect(try await h.gmail.listDrafts(pageToken: nil, q: nil, maxResults: 50).drafts?.count == 1)
        #expect(await h.gmail.callCount(.createDraft) == 1)
        await b.stop()
        await a.stop()
        try storeB.close()
    }

    @Test func whatAnOwnerThatEndedLeftInFlightIsRequeuedAtTheNextHeartbeat() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let drainer = try #require(await engine.drainer(for: h.account))
        await drainer.stop()
        let receipt = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app)
        let op = receipt.operationIDs[0]
        _ = try h.store.claimReadyOperations(account: h.account, now: h.clock.now, limit: 10, ownerID: "ended-app")
        h.clock.advance(by: OwnershipManager.heartbeatInterval)
        try await eventually("requeued at the heartbeat") {
            let item = try h.store.operation(op)
            return item?.status == .pending && item?.attempts == 1
        }
        #expect(await drainer.drainOnce().succeeded == 1)
        #expect(!(await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
        await engine.stop()
    }
}

func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
}
