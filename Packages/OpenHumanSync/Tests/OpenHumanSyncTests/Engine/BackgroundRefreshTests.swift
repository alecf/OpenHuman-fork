import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

@Suite struct BackgroundRefreshTests {
    private func syncedHarness(threads: Int = 3, clock: TestClock? = nil, gmail: FakeGmail? = nil,
                               onDisk: Bool = false) async throws -> EngineHarness {
        let h = try await EngineHarness(onDisk: onDisk, threads: threads, clock: clock, gmail: gmail)
        try await AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: h.clock).sync(reason: "launch")
        await h.gmail.resetAccounting()
        return h
    }

    private func queue(_ h: EngineHarness, _ engine: MailEngine, count: Int) async throws {
        for (index, thread) in h.threads.prefix(count).enumerated() {
            let ref = try h.ref(thread)
            let action: MailAction = switch index % 3 {
            case 0: .archive([ref])
            case 1: .star([ref])
            default: .markRead([ref])
            }
            _ = try await engine.perform(action, origin: .app)
        }
        #expect(try h.ops([.pending]).count == count)
    }

    private func localDraft(_ h: EngineHarness, subject: String = "Synthetic background upload") throws -> DraftID {
        try h.store.createDraft(account: h.account, mode: .new, replyTo: nil,
                                content: DraftContent(to: [EmailAddress(email: "bob@example.com")], cc: [], bcc: [],
                                                      subject: subject, bodyHTML: "<p>Synthetic body</p>", attachments: []),
                                origin: .user, reviewState: .none, agentNote: nil, extraHeaders: [:])
    }

    private func gmailDraftIDs(_ h: EngineHarness) async throws -> [String] {
        try await h.gmail.listDrafts(pageToken: nil, q: nil, maxResults: 500).drafts?.map(\.id) ?? []
    }

    private func queuedUploadAndArchive(_ h: EngineHarness) throws -> (draft: DraftID, upload: OperationID, archive: OperationID) {
        let draft = try localDraft(h)
        let upload = try h.store.saveDraftRemotely(draft)
        let archive = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        return (draft, upload, archive)
    }

    private func expectUploadedOnce(_ h: EngineHarness, _ probe: ProbeGmail, draft: DraftID, upload: OperationID,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(try h.store.operation(upload)?.status == .succeeded, sourceLocation: sourceLocation)
        let saved = try #require(try h.store.draft(draft)?.gmailDraftID, sourceLocation: sourceLocation).rawValue
        #expect(try await gmailDraftIDs(h) == [saved], sourceLocation: sourceLocation)
        #expect(probe.writes.filter { $0.method == .createDraft }.count == 1, sourceLocation: sourceLocation)
    }

    @Test func refreshOnceRunsOneHistoryPassAndNeverBackfills() async throws {
        let h = try await syncedHarness()
        let arrived = await h.gmail.deliver(subject: "Synthetic arrival")
        let report = await h.engine().refreshOnce(deadline: h.clock.now.addingTimeInterval(30))

        #expect(await h.gmail.callCount(.listHistory) == 1)
        for method: GmailMethod in [.listMessages, .listThreads, .getLabel, .getProfile] {
            #expect(await h.gmail.callCount(method) == 0, "\(method.rawValue)")
        }
        #expect(report.syncs.map(\.kind) == ["incremental"])
        #expect(report.syncs.first?.error == nil)
        #expect(!report.deadlineReached && report.ownedElsewhere.isEmpty)
        #expect(try h.store.thread(account: h.account, gmailThreadID: GmailThreadID(arrived.threadID)) != nil)
        let status = try h.store.syncStatus(account: h.account)
        #expect(status.phase == .inboxReady)
        #expect(!status.backfillComplete)
        #expect(try h.store.lease(account: h.account) == nil, "the one-shot refresh hands its lease back")
    }

    @Test func theRefreshPassNeverSpawnsABackfill() async throws {
        let h = try await syncedHarness()
        let item = try #require(try h.store.accounts().first)
        let runtime = try #require(await h.engine().makeRuntime(item))

        let outcome = await runtime.refresh(until: h.clock.now.addingTimeInterval(30), maxOperations: 5)

        #expect(try outcome.sync?.get().kind == "incremental")
        #expect(await runtime.syncer.backfillTaskID == 0)
        await runtime.stop()
    }

    @Test func refreshOnceDrainsAtMostTheGivenNumberOfOperations() async throws {
        let h = try await syncedHarness(threads: 5)
        let engine = h.engine()
        try await queue(h, engine, count: 5)

        let report = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(60), maxOperations: 2)

        let drained = try #require(report.operations[h.account])
        #expect(drained.claimed == 2 && drained.succeeded == 2)
        #expect(try h.ops([.succeeded]).count == 2)
        #expect(try h.ops([.pending]).count == 3)
        #expect(!(await h.serverLabels(ofThread: h.threads[0])).contains("INBOX"))
        #expect(await h.serverLabels(ofThread: h.threads[1]).contains("STARRED"))
        #expect(await h.serverLabels(ofThread: h.threads[2]).contains("UNREAD"))
        #expect(await h.serverLabels(ofThread: h.threads[3]).contains("INBOX"))
    }

    @Test func theDrainStopsBetweenOperationsOnceTheInjectedClockPassesTheDeadline() async throws {
        let h = try await syncedHarness()
        let engine = h.engine()
        try await queue(h, engine, count: 3)
        let clock = h.clock
        let deadline = clock.now.addingTimeInterval(30)
        await h.gmail.afterNext(.batchModify) { _ in clock.advance(to: deadline) }

        let report = await engine.refreshOnce(deadline: deadline)

        #expect(report.deadlineReached)
        let drained = try #require(report.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 2)
        #expect(await h.gmail.callCount(.batchModify) == 1)
        #expect(try h.ops([.succeeded]).count == 1)
        #expect(try h.ops([.pending]).count == 2)
    }

    @Test func workThatRunsPastTheDeadlineSkipsTheDrain() async throws {
        let h = try await syncedHarness()
        let engine = h.engine()
        try await queue(h, engine, count: 2)
        let clock = h.clock
        await h.gmail.afterNext(.listHistory) { _ in clock.advance(by: .seconds(40)) }

        let report = await engine.refreshOnce(deadline: clock.now.addingTimeInterval(30))

        #expect(report.deadlineReached)
        #expect(report.operations[h.account] == nil)
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(try h.ops([.pending]).count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aHungGmailCallIsCancelledAtTheDeadline() async throws {
        let clock = TestClock(now: currentMinute())
        let deadline = clock.now.addingTimeInterval(25)
        let gmail = FakeGmail(accountEmail: "me@example.com", clock: TripwireClock(clock, tripsAt: deadline),
                              startDate: clock.now.addingTimeInterval(-86_400))
        let h = try await syncedHarness(clock: clock, gmail: gmail)
        let engine = h.engine()
        try await queue(h, engine, count: 1)
        let before = try h.store.syncStatus(account: h.account).historyID
        await gmail.latency(.listHistory, .seconds(1))

        let report = await engine.refreshOnce(deadline: deadline)

        #expect(report.deadlineReached)
        #expect(report.syncs.map(\.error) == ["cancelled"])
        #expect(report.operations[h.account] == nil)
        #expect(await gmail.callCount(.listHistory) == 1)
        #expect(try h.store.syncStatus(account: h.account).historyID == before)
        #expect(try h.ops([.pending]).count == 1)
    }

    @Test func aPassedDeadlineDoesNoWork() async throws {
        let h = try await syncedHarness()
        let report = await h.engine().refreshOnce(deadline: h.clock.now)
        #expect(report.deadlineReached)
        #expect(report.syncs.isEmpty)
        #expect(await h.gmail.callLog.isEmpty)
    }

    @Test func anAccountLeasedByAnotherLiveProcessIsSkipped() async throws {
        let h = try await syncedHarness()
        let other = OwnershipManager(store: h.store, identity: ProcessIdentity(writerID: "other-writer", pid: 1,
                                                                               host: "another-host"),
                                     kind: "cli", clock: h.clock)
        #expect(await other.acquire(h.account))

        let report = await h.engine().refreshOnce(deadline: h.clock.now.addingTimeInterval(30))

        #expect(report.ownedElsewhere == [h.account])
        #expect(report.syncs.isEmpty)
        #expect(await h.gmail.callLog.isEmpty)
    }

    @Test func theBackgroundEventPausesBackfillUntilTheAppIsActiveAgain() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        let runtime = try #require(await engine.runtime(for: h.account))

        await engine.handle(.didEnterBackground)
        #expect(await runtime.syncer.isBackfillPaused)
        #expect(await !runtime.syncer.isBackfillRunning)
        #expect(await !runtime.active)
        let spawned = await runtime.syncer.backfillTaskID

        let report = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(30))
        #expect(report.syncs.count == 1 && report.syncs.first?.error == nil)
        #expect(await runtime.syncer.backfillTaskID == spawned)

        await engine.handle(.didBecomeActive)
        #expect(await !runtime.syncer.isBackfillPaused)
        #expect(await runtime.active)
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1))) func theBackgroundEventFlushesAPendingSendInsideItsUndoWindow() async throws {
        let h = try await EngineHarness()
        let system = TestSystemEvents()
        let engine = h.engine(systemEvents: system)
        var events = engine.events.makeAsyncIterator()
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic background send"), threadID: nil)
        let draft = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)))
        await engine.start()
        let receipt = try await engine.send(draft, authorization: .userConfirmed, undoWindow: .seconds(600))
        h.clock.advance(by: .seconds(120))
        #expect(try h.store.operation(receipt.sendOperationID)?.status == .pending)

        system.send(.didEnterBackground)
        while let event = await events.next() {
            if case .sent(draft, _) = event { break }
            if case .sendFailed(draft, let reason) = event {
                Issue.record("send failed: \(reason)")
                break
            }
        }

        #expect(h.clock.now < receipt.sendAfter, "sent before the undo window ended")
        #expect(await h.gmail.callCount(.sendDraft) == 1)
        try await h.expectOneCleanSentMessage("background flush")
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aRefreshAskedForDuringAnotherSharesItsPass() async throws {
        let h = try await syncedHarness()
        let probe = ProbeGmail(h.gmail)
        let engine = h.engine(factory: FixedGmailFactory(api: probe))
        let hold = probe.holdAfterCommit(.listHistory)
        let deadline = h.clock.now.addingTimeInterval(20)

        let first = await engine.refreshPass(deadline: deadline, maxOperations: 5)
        await hold.arrival()
        let second = await engine.refreshPass(deadline: deadline.addingTimeInterval(60), maxOperations: 1)
        #expect(second == first)
        hold.open()
        let report = await first.value

        #expect(report.syncs.map(\.error) == [nil])
        #expect(await h.gmail.callCount(.listHistory) == 1)
        let next = await engine.refreshPass(deadline: deadline, maxOperations: 5)
        #expect(next != first, "a finished pass is not reused")
        _ = await next.value
        #expect(await h.gmail.callCount(.listHistory) == 2)
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test func aStartedEngineRefreshesWithItsOwnRuntimeAndKeepsItsLease() async throws {
        let h = try await syncedHarness()
        let factory = CountingFactory(h.gmail)
        let engine = h.engine(factory: factory)
        await engine.start()
        let runtime = try #require(await engine.runtime(for: h.account))
        #expect(factory.clients == 1)

        let report = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20))

        #expect(report.syncs.count == 1 && report.ownedElsewhere.isEmpty)
        #expect(factory.clients == 1, "no second runtime")
        #expect(await engine.runtime(for: h.account) === runtime)
        #expect(try h.store.lease(account: h.account)?.ownerID == h.store.writerID)
        await engine.stop()
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func startingDuringABackgroundRefreshEndsItBeforeTheEngineTakesOver() async throws {
        let h = try await syncedHarness()
        let probe = ProbeGmail(h.gmail)
        let factory = CountingFactory(probe)
        let engine = h.engine(factory: factory)
        let hold = probe.holdAfterCommit(.listHistory)
        let refreshing = Task { await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20)) }
        await hold.arrival()
        #expect(factory.clients == 1)

        await engine.start()

        #expect(hold.wasCancelled, "the background pass ended before start went on")
        hold.open()
        let report = await refreshing.value
        #expect(report.syncs.map(\.error) == ["cancelled"] && report.operations.isEmpty)
        #expect(factory.clients == 2)
        #expect(await engine.runtime(for: h.account) != nil)
        #expect(try h.store.lease(account: h.account)?.ownerID == h.store.writerID)
        await engine.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aDraftUploadInFlightAtTheDeadlineFinishesAndIsNotRepeated() async throws {
        let h = try await syncedHarness()
        let probe = ProbeGmail(h.gmail)
        let engine = h.engine(factory: FixedGmailFactory(api: probe))
        let queued = try queuedUploadAndArchive(h)
        let hold = probe.holdAfterCommit(.createDraft)
        let deadline = h.clock.now.addingTimeInterval(20)
        let refreshing = Task { await engine.refreshOnce(deadline: deadline) }
        await hold.arrival()

        h.clock.advance(to: deadline.addingTimeInterval(1))
        hold.open()
        let report = await refreshing.value

        #expect(!hold.wasCancelled)
        #expect(report.deadlineReached)
        let drained = try #require(report.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 1)
        try await expectUploadedOnce(h, probe, draft: queued.draft, upload: queued.upload)
        let archive = try #require(try h.store.operation(queued.archive))
        #expect(archive.status == .pending && archive.attempts == 0, "no new operation starts after the deadline")
        #expect(await h.gmail.callCount(.batchModify) == 0)
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheRefreshLetsAnUploadInFlightFinish() async throws {
        let h = try await syncedHarness()
        let probe = ProbeGmail(h.gmail)
        let engine = h.engine(factory: FixedGmailFactory(api: probe))
        let queued = try queuedUploadAndArchive(h)
        let hold = probe.holdAfterCommit(.createDraft)
        let refreshing = Task { await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20)) }
        await hold.arrival()

        refreshing.cancel()
        hold.open()
        let report = await refreshing.value

        #expect(!hold.wasCancelled)
        #expect(!report.deadlineReached)
        let drained = try #require(report.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 1)
        try await expectUploadedOnce(h, probe, draft: queued.draft, upload: queued.upload)
        let archive = try #require(try h.store.operation(queued.archive))
        #expect(archive.status == .pending && archive.attempts == 0)
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aHungUploadKeepsItsClaimAndARenewedLeaseUntilTheTransportGivesUp() async throws {
        let h = try await syncedHarness()
        let probe = ProbeGmail(h.gmail)
        let clock = AnnouncingClock(h.clock)
        let engine = MailEngine(store: h.store, gmailFactory: FixedGmailFactory(api: probe), tokenStore: nil, oauthClient: nil,
                                configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test",
                                                                   gmail: engineGmailConfig, clock: clock),
                                systemEvents: nil)
        let draft = try localDraft(h)
        let upload = try h.store.saveDraftRemotely(draft)
        let hold = probe.holdAfterCommit(.createDraft)
        let start = h.clock.now
        let refreshing = Task { await engine.refreshOnce(deadline: start.addingTimeInterval(20)) }
        await hold.arrival()
        await clock.sleeper(at: start.addingTimeInterval(15))
        for beat in 1...4 {
            h.clock.advance(to: start.addingTimeInterval(TimeInterval(15 * beat)))
            await clock.sleeper(at: start.addingTimeInterval(TimeInterval(15 * (beat + 1))))
        }
        refreshing.cancel()

        #expect(!hold.wasCancelled)
        #expect(try h.store.operation(upload)?.status == .inFlight)
        #expect(try h.store.lease(account: h.account)?.heartbeatAt == start.addingTimeInterval(60))
        let rival = OwnershipManager(store: h.store, identity: ProcessIdentity(writerID: "other-writer", pid: 1,
                                                                               host: "another-host"),
                                     kind: "cli", clock: h.clock)
        #expect(await !rival.acquire(h.account), "renewed past the lease's 45 s lifetime")

        hold.fail(.transport(.timedOut))
        _ = await refreshing.value
        let timedOut = try #require(try h.store.operation(upload))
        #expect(timedOut.status == .pending && timedOut.attempts == 1, "a transport failure counts the attempt")
        #expect(try h.store.lease(account: h.account) == nil)

        h.clock.advance(by: OperationDrainer.backoff(attempts: 0))
        let retry = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20))
        #expect(retry.operations[h.account]?.succeeded == 1)
        try await expectUploadedOnce(h, probe, draft: draft, upload: upload)
        #expect(probe.writes.filter { $0.method == .updateDraft }.count == 1, "the retry adopted the first attempt's draft")
    }

    @Test func opsReleasedAtTheDeadlineKeepTheirAttemptsOriginScheduleAndLastError() async throws {
        let h = try await syncedHarness()
        let engine = h.engine()
        try await queue(h, engine, count: 3)
        await h.gmail.failNext(.batchModify, with: .server(status: 500, message: "synthetic"), count: 3)
        let failed = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20))
        #expect(failed.operations[h.account]?.retried == 3)
        let before = try h.ops([.pending])
        #expect(before.count == 3 && before.allSatisfy { $0.attempts == 1 && $0.lastErrorCode == "server" })
        h.clock.advance(by: OperationDrainer.backoff(attempts: 0))
        let clock = h.clock
        let deadline = clock.now.addingTimeInterval(20)
        await h.gmail.afterNext(.batchModify) { _ in clock.advance(to: deadline) }

        let report = await engine.refreshOnce(deadline: deadline)

        let drained = try #require(report.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 2)
        let after = try h.ops([.pending])
        #expect(after.count == 2)
        for op in after {
            let earlier = try #require(before.first { $0.id == op.id })
            #expect(op.attempts == 1 && op.origin == .app && op.payload == earlier.payload)
            #expect(op.notBefore == earlier.notBefore && op.dependsOn == earlier.dependsOn)
            #expect(op.lastErrorCode == "server" && op.lastErrorMessage == earlier.lastErrorMessage)
        }
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test func aRefusedOperationStaysRefusedAfterADeadlineReleaseAndUnderALimit() async throws {
        let h = try await syncedHarness(onDisk: true)
        defer { h.cleanup() }
        let engine = h.engine()
        let mine = try h.store.apply(.archive([try h.ref(h.threads[0])]), origin: .app).operationIDs[0]
        let cli = try h.store.apply(.star([try h.ref(h.threads[1])]), origin: .cli).operationIDs[0]
        let remote = try await h.gmail.createDraft(rawRFC822: rawDraft(subject: "Synthetic refused send"), threadID: nil)
        let fetched = try #require(try await engine.fetchDraft(account: h.account, gmailDraftID: GmailDraftID(remote.id)))
        let receipt = try h.store.send(fetched, undoWindow: .zero, origin: .app)
        let send = receipt.sendOperationID
        try ExternalOriginTests.setQueuedOrigin("agent", of: send, in: h.store)
        h.advancePast(receipt)
        let upsert = try h.store.saveDraftRemotely(try localDraft(h, subject: "Synthetic user draft"))
        try ExternalOriginTests.setQueuedOrigin("agent", of: upsert, in: h.store)
        let refused = [cli, send, upsert]
        let before = try refused.map { try #require(try h.store.operation($0)) }
        await h.gmail.resetAccounting()
        let clock = h.clock
        let deadline = clock.now.addingTimeInterval(20)
        await h.gmail.afterNext(.batchModify) { _ in clock.advance(to: deadline) }

        let cut = await engine.refreshOnce(deadline: deadline)

        let drained = try #require(cut.operations[h.account])
        #expect(drained.succeeded == 1 && drained.released == 3)
        #expect(try h.store.operation(mine)?.status == .succeeded)
        for earlier in before {
            let op = try #require(try h.store.operation(earlier.id))
            #expect(op.status == .pending && op.attempts == 0 && op.origin == earlier.origin, "\(op.kind)")
            #expect(op.notBefore == earlier.notBefore && op.lastErrorCode == nil, "\(op.kind)")
        }

        let limited = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20), maxOperations: 2)
        #expect(limited.operations[h.account]?.claimed == 2 && limited.operations[h.account]?.failed == 2)
        let rest = await engine.refreshOnce(deadline: h.clock.now.addingTimeInterval(20), maxOperations: 2)
        #expect(rest.operations[h.account]?.claimed == 1 && rest.operations[h.account]?.failed == 1)
        for id in refused {
            let op = try #require(try h.store.operation(id))
            #expect(op.status == .failed && op.lastErrorCode == "not_applied_outside_app", "\(op.kind)")
        }
        #expect(await h.gmail.callCount(.batchModify) == 1)
        for method: GmailMethod in [.sendDraft, .createDraft, .updateDraft, .modifyMessage] {
            #expect(await h.gmail.callCount(method) == 0, "\(method.rawValue)")
        }
        #expect(!(await h.serverLabels(ofThread: h.threads[1])).contains("STARRED"))
        #expect(try await sentOnGmail(h.gmail).isEmpty)
    }

    @Test func theLeaseIsHandedBackWhenTheRefreshFails() async throws {
        let h = try await syncedHarness()
        await h.gmail.failNext(.listHistory, with: .server(status: 500, message: "synthetic"))
        let failed = await h.engine().refreshOnce(deadline: h.clock.now.addingTimeInterval(20))
        #expect(failed.syncs.count == 1 && failed.syncs.first?.error != nil)
        #expect(try h.store.lease(account: h.account) == nil)

        let noClient = await h.engine(factory: ThrowingFactory()).refreshOnce(deadline: h.clock.now.addingTimeInterval(20))
        #expect(noClient.syncs.isEmpty && noClient.ownedElsewhere.isEmpty)
        #expect(try h.store.lease(account: h.account) == nil)
    }

    @Test func phoneWindowDefaultsAreEngineConfiguration() async throws {
        #expect(LocalWindow.phone == LocalWindow(metadataHorizonDays: 365, bodyHorizonDays: 30, downloadBodies: false,
                                                 backfillUnitsPerMinute: 1_500))
        #expect(LocalWindow.standard == LocalWindow(metadataHorizonDays: nil, bodyHorizonDays: 90, downloadBodies: true))
        #if os(macOS)
        #expect(LocalWindow.platformDefault == .standard)
        #endif
        let h = try await EngineHarness(threads: 0)

        let mac = await h.engine().runtimeEnvironment()
        #expect(mac.syncSettings.metadataHorizon == nil)
        #expect(mac.syncSettings.bodyHorizon == .seconds(90 * 86_400))
        #expect(mac.syncSettings.backfillUnitsPerMinute == engineGmailConfig.unitsPerMinute / 2)
        #expect(AccountRuntime.bodyPolicy(h.store, downloadBodies: mac.downloadBodies).enabled)

        let phone = MailEngine(store: h.store, gmailFactory: h.factory, tokenStore: nil, oauthClient: nil,
                               configuration: EngineConfiguration(role: .app, appVersion: "0.0.0-test",
                                                                  gmail: engineGmailConfig, clock: h.clock,
                                                                  window: .phone),
                               systemEvents: nil)
        let env = await phone.runtimeEnvironment()
        #expect(env.syncSettings.metadataHorizon == .seconds(365 * 86_400))
        #expect(env.syncSettings.bodyHorizon == .seconds(30 * 86_400))
        #expect(env.syncSettings.backfillUnitsPerMinute == 1_500)
        #expect(!AccountRuntime.bodyPolicy(h.store, downloadBodies: env.downloadBodies).enabled)
        #expect(try h.store.setting(.bodyHorizonDays, scope: .global) == 90, "the defaults are not written to the store")

        try h.store.setSetting(.bodyHorizonDays, 60, scope: .global)
        try h.store.setSetting(.metadataHorizonDays, 730, scope: .global)
        try h.store.setSetting(.downloadBodies, true, scope: .global)
        let chosen = await phone.runtimeEnvironment()
        #expect(chosen.syncSettings.bodyHorizon == .seconds(60 * 86_400))
        #expect(chosen.syncSettings.metadataHorizon == .seconds(730 * 86_400))
        #expect(AccountRuntime.bodyPolicy(h.store, downloadBodies: chosen.downloadBodies).enabled)
    }
}

private final class CountingFactory: GmailClientFactory {
    let api: any GmailAPI
    private let made = Mutex(0)

    init(_ api: any GmailAPI) { self.api = api }

    var clients: Int { made.withLock { $0 } }

    func client(for accountEmail: String) throws -> GmailAPI {
        made.withLock { $0 += 1 }
        return api
    }
}

private struct ThrowingFactory: GmailClientFactory {
    func client(for accountEmail: String) throws -> GmailAPI { throw GmailError.transport(.notConnected) }
}

private final class AnnouncingClock: OHClock {
    private struct Waiter {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Never>
    }
    let base: TestClock
    private let state = Mutex<(announced: Set<Date>, waiters: [Waiter])>(([], []))

    init(_ base: TestClock) { self.base = base }

    var now: Date { base.now }

    func sleep(until deadline: Date) async throws {
        let ready = state.withLock { s -> [Waiter] in
            s.announced.insert(deadline)
            defer { s.waiters.removeAll { $0.deadline == deadline } }
            return s.waiters.filter { $0.deadline == deadline }
        }
        for waiter in ready { waiter.continuation.resume() }
        try await base.sleep(until: deadline)
    }

    func sleeper(at deadline: Date) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.announced.contains(deadline) || Task.isCancelled { return true }
                    s.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let index = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: index)
            }
            waiter?.continuation.resume()
        }
    }
}

private final class TripwireClock: OHClock {
    let base: TestClock
    let trip: Date

    init(_ base: TestClock, tripsAt trip: Date) {
        self.base = base
        self.trip = trip
    }

    var now: Date { base.now }

    func sleep(until deadline: Date) async throws {
        base.advance(to: trip)
        try await base.sleep(until: .distantFuture)
    }
}
