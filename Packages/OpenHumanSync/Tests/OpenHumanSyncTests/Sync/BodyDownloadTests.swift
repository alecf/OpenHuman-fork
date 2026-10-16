import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

private func bodies(_ h: SyncHarness) throws -> BodyCounts { try h.store.bodyCounts(account: h.account) }

private let readMethods: Set<GmailMethod> = [.getProfile, .listSendAs, .listLabels, .getLabel, .listThreads, .getThread,
                                             .listMessages, .getMessage, .getAttachment, .listDrafts, .getDraft,
                                             .listHistory]

private final class Flag: Sendable {
    private let value: Mutex<Bool>
    init(_ initial: Bool = false) { value = Mutex(initial) }
    var isOn: Bool { value.withLock { $0 } }
    func set(_ on: Bool) { value.withLock { $0 = on } }
}

@Suite struct BodyDownloadTests {
    @Test(.timeLimit(.minutes(20))) func aNineteenThousandMessageMailboxConvergesAtTheBackfillBudget() async throws {
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings()
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        var seeded = SeededMailbox()
        let end = testNow.addingTimeInterval(-3_600)
        for t in 0..<1_900 {
            let first = await h.gmail.deliver(subject: "Long thread \(t)", body: "Body \(t).0", labels: ["INBOX"],
                                              date: end.addingTimeInterval(-Double(1_900 - t) * 1_800))
            for m in 1..<10 {
                await h.gmail.deliver(subject: "Re: Long thread \(t)", body: "Body \(t).\(m)", labels: ["INBOX"],
                                      threadID: first.threadID,
                                      date: end.addingTimeInterval(-Double(1_900 - t) * 1_800 + Double(m) * 180))
            }
            seeded.threads.append(first.threadID)
            seeded.messages += 10
        }
        #expect(seeded.messages == 19_000)
        try await h.syncer.sync(reason: "launch")
        let relaunched = h.relaunched(api: recorder, settings: settings)
        let progress = ProgressLog(relaunched.observeProgress())
        defer { progress.stop() }

        recorder.setHook { call, _ in
            if call.method == .getMessage && call.priority == .backfill { withUnsafeCurrentTask { $0?.cancel() } }
        }
        #expect(await h.syncer.runBackfill() == .cancelled)
        recorder.setHook(nil)
        let metadataOnly = try bodies(h)
        #expect(metadataOnly.pending + metadataOnly.stored == seeded.messages && metadataOnly.stored < 100)
        recorder.reset()
        await h.gmail.resetAccounting()

        let started = clock.now
        #expect(await relaunched.runBackfill() == .complete)
        let elapsed = clock.now.timeIntervalSince(started)

        let done = try bodies(h)
        #expect(done == BodyCounts(stored: seeded.messages, pending: 0, failed: 0))
        let fetchCalls = recorder.calls(.getMessage)
        let fetchedBodies = fetchCalls.reduce(0) { $0 + $1.items }
        #expect(fetchedBodies >= metadataOnly.pending && fetchedBodies <= metadataOnly.pending + settings.bodyChunk)
        #expect(fetchCalls.allSatisfy { $0.priority == .backfill && $0.items <= settings.bodyChunk })
        #expect(recorder.calls.allSatisfy { readMethods.contains($0.method) })
        let bodyUnits = fetchedBodies * QuotaCost.units(.getMessage)
        #expect(await h.gmail.units(for: .getMessage) == bodyUnits)
        let spent = await relaunched.pacer.units
        #expect(spent == bodyUnits && recorder.calls.allSatisfy { $0.method == .getMessage })
        let rate = Double(settings.backfillUnitsPerMinute) / 60
        #expect(Double(spent) <= Double(settings.backfillUnitsPerMinute) / 4 + rate * elapsed + 1)
        #expect(Double(spent) >= rate * elapsed * 0.9)
        #expect(elapsed > 6_000)

        try await eventually("search progress") { progress.all.contains { $0.stage == .searchBodies } }
        let search = progress.all.filter { $0.stage == .searchBodies }
        #expect(search.contains { $0.statusText?.hasPrefix("Downloading messages for search: ") == true })
        let counts = search.map(\.bodiesDone)
        #expect(counts == counts.sorted())
        #expect(relaunched.progress.bodiesDone == seeded.messages && relaunched.progress.bodiesTotal == seeded.messages)
        recorder.reset()
        #expect(await h.relaunched(api: recorder, settings: settings).runBackfill() == .complete)
        #expect(recorder.calls(.getMessage).isEmpty)
    }

    @Test func aQuitResumesFromBodyStateAndFetchesNewestFirst() async throws {
        let settings = backfillSettings(pageSize: 100)
        let h = try SyncHarness(settings: settings, recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 400, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        recorder.setHook { call, n in
            if call.method == .getMessage && call.priority == .backfill && n == 6 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        #expect(await h.syncer.runBackfill() == .cancelled)
        recorder.setHook(nil)
        let partial = try bodies(h)
        #expect(partial.stored > 0 && partial.pending > 0 && partial.stored + partial.pending == seeded.messages)
        let wanted = try h.store.messagesNeedingBodies(account: h.account, newerThan: .distantPast, limit: 1)
        let firstWanted = try #require(wanted.first)
        let newestPending = try #require(try h.message(firstWanted.rawValue)).date
        let all = try await serverMessageIDs(h.gmail)
        let storedDates = try all.compactMap { try h.message($0) }.filter { $0.bodyState == .stored }.map(\.date)
        #expect(newestPending <= (storedDates.min() ?? .distantFuture))

        recorder.reset()
        #expect(await h.relaunched(api: recorder, settings: settings).runBackfill() == .complete)
        let again = recorder.calls(.getMessage).reduce(0) { $0 + $1.items }
        #expect(again == partial.pending)
        #expect(try bodies(h) == BodyCounts(stored: seeded.messages, pending: 0, failed: 0))
    }

    @Test func theDeepBodyPassCountsTheTableOncePerPass() async throws {
        let settings = backfillSettings(pageSize: 100)
        let h = try SyncHarness(settings: settings, recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 400, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = h.relaunched(api: recorder, settings: settings)
        #expect(await syncer.runBackfill() == .complete)
        let chunks = recorder.calls(.getMessage).filter { $0.priority == .backfill }.count
        #expect(chunks >= 10, "the pass really ran in many chunks")
        #expect(await syncer.bodyCountQueries == 1)
        #expect(try bodies(h) == BodyCounts(stored: seeded.messages, pending: 0, failed: 0))
        #expect(syncer.progress.bodiesDone == seeded.messages && syncer.progress.bodiesTotal == seeded.messages)
    }

    @Test func theSwitchAndTheCapAreHonouredLive() async throws {
        let policy = Mutex(BodyDownloadPolicy(enabled: false))
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings(pageSize: 100)
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        let seeded = await h.gmail.seedMailbox(count: 400, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = AccountSyncer(account: h.account, store: h.store, api: recorder, clock: clock, settings: settings,
                                   bodyPolicy: { policy.withLock { $0 } })

        #expect(await syncer.runBackfill() == .complete)
        let horizonOnly = try bodies(h)
        #expect(horizonOnly.stored > 0 && horizonOnly.pending > 0)
        #expect(horizonOnly.stored + horizonOnly.pending == seeded.messages)

        policy.withLock { $0 = BodyDownloadPolicy(enabled: true, maxMessages: horizonOnly.stored + 50) }
        await syncer.bodySettingsChanged()
        #expect(await syncer.runBackfill() == .complete)
        #expect(try bodies(h).stored == horizonOnly.stored + 50)
        #expect(syncer.progress.bodiesDone == horizonOnly.stored + 50 && syncer.progress.bodiesTotal == horizonOnly.stored + 50)

        policy.withLock { $0 = BodyDownloadPolicy() }
        await syncer.bodySettingsChanged()
        #expect(await syncer.runBackfill() == .complete)
        #expect(try bodies(h).pending == 0)

        let h2 = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder2 = try #require(h2.recorder)
        await h2.gmail.seedMailbox(count: 400, end: testNow.addingTimeInterval(-3_600))
        try await h2.syncer.sync(reason: "launch")
        let live = Mutex(BodyDownloadPolicy())
        let syncer2 = AccountSyncer(account: h2.account, store: h2.store, api: recorder2, clock: clock, settings: settings,
                                    bodyPolicy: { live.withLock { $0 } })
        recorder2.setHook { call, n in
            if call.method == .getMessage && call.priority == .backfill && n == 12 { live.withLock { $0 = BodyDownloadPolicy(enabled: false) } }
        }
        #expect(await syncer2.runBackfill() == .complete)
        let stopped = try bodies(h2)
        #expect(stopped.pending > 0 && recorder2.calls(.getMessage).count <= 13)
    }

    @Test(arguments: ["offline", "lowPower", "reader", "queue"])
    func theDownloadStandsAsideFor(_ reason: String) async throws {
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings(pageSize: 100)
        let reachable = Flag(true), constrained = Flag(false)
        let gate = BackfillGate(isReachable: { reachable.isOn }, isConstrained: { constrained.isOn })
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        await h.gmail.seedMailbox(count: 120, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = AccountSyncer(account: h.account, store: h.store, api: recorder, clock: clock, settings: settings,
                                   gate: gate)
        let progress = ProgressLog(syncer.observeProgress())
        defer { progress.stop() }

        let raised = Mutex<Int?>(nil), atRelease = Mutex<Int?>(nil)
        recorder.setHook { call, n in
            guard call.method == .getMessage, call.priority == .backfill, n == 3 else { return }
            raised.withLock { $0 = recorder.calls.count }
            switch reason {
            case "offline": reachable.set(false)
            case "lowPower": constrained.set(true)
            case "reader": gate.beginInteractive()
            default: gate.beginDraining()
            }
            Task {
                while clock.sleeps.filter({ $0 == BackfillGate.recheck.timeInterval }).count < 3 { await Task.yield() }
                atRelease.withLock { $0 = recorder.calls.count }
                switch reason {
                case "offline": reachable.set(true)
                case "lowPower": constrained.set(false)
                case "reader": gate.endInteractive(now: clock.now)
                default: gate.endDraining()
                }
            }
        }
        #expect(await syncer.runBackfill() == .complete)
        #expect(raised.withLock { $0 } != nil && raised.withLock { $0 } == atRelease.withLock { $0 })
        #expect(try bodies(h).pending == 0)
        let expected: BackfillHold = ["offline": .offline, "lowPower": .lowPower, "reader": .interactive][reason] ?? .queueDrain
        #expect(progress.all.contains { $0.hold == expected })
        #expect(syncer.progress.hold == nil)
    }

    @Test func aPausedDownloadSaysSoInTheStatusLine() {
        let offline = SyncProgress(stage: .searchBodies, isRunning: true, bodiesDone: 1_240, bodiesTotal: 19_000, hold: .offline)
        #expect(offline.statusText == "Message download paused, offline: 1,240 of 19,000")
    }

    @Test func interactiveFetchesAreNeverStarvedByTheDownload() async throws {
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings(pageSize: 100)
        let gate = BackfillGate()
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        await h.gmail.seedMailbox(count: 300, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let syncer = AccountSyncer(account: h.account, store: h.store, api: recorder, clock: clock, settings: settings,
                                   gate: gate)
        let oldest = try #require(try h.store.messagesNeedingBodies(account: h.account, newerThan: .distantPast, limit: 400).last)
        recorder.reset()
        let fetcher = BodyFetcher(account: h.account, store: h.store, api: recorder)

        let opened = Flag()
        recorder.setHook { call, n in
            guard call.method == .getMessage, call.priority == .backfill, n == 5, !opened.isOn else { return }
            opened.set(true)
            gate.beginInteractive()
            Task {
                _ = try? await fetcher.ensureBody(oldest, priority: .interactive)
                gate.endInteractive(now: clock.now)
            }
        }
        #expect(await syncer.runBackfill() == .complete)
        let calls = recorder.calls.filter { $0.method == .getMessage }
        let readerAt = try #require(calls.firstIndex { $0.priority == .interactive })
        #expect(readerAt <= 5)
        #expect(calls[readerAt...].first { $0.priority == .backfill } != nil)
        #expect(clock.sleeps.contains(BackfillGate.recheck.timeInterval))
        #expect(try bodies(h).pending == 0)
        #expect(calls[readerAt].items == 1)
    }

    @Test func aRateLimitBacksOffExponentiallyAndTheDownloadResumes() async throws {
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings(pageSize: 100)
        let h = try SyncHarness(settings: settings, clock: clock, recording: true)
        let recorder = try #require(h.recorder)
        await h.gmail.seedMailbox(count: 150, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        let gmail = h.gmail
        let limited = Mutex(0)
        recorder.setHook { call, _ in
            if call.method == .getMessage, call.priority == .backfill, limited.withLock({ $0 += 1; return $0 }) <= 3 {
                await gmail.failNext(.getMessage, with: .rateLimited(retryAfter: nil))
            }
        }
        #expect(await h.syncer.runBackfill() == .complete)
        let pauses = clock.sleeps.filter { [60.0, 120.0, 240.0].contains($0) }
        #expect(pauses == [60, 120, 240])
        #expect(try bodies(h).pending == 0)
        let status = try h.status()
        #expect(status.consecutiveFailures == 0 && status.lastError == nil)
        #expect(await h.syncer.rateLimitStreak == 0)
    }

    @Test func theDownloadSendsOnlyGETsThroughTheLiveStack() async throws {
        let clock = InstantClock(now: testNow)
        let metrics = SyncMetricsCollector()
        var wireBox: FakeGmailTransport?
        let h = try SyncHarness(settings: backfillSettings(pageSize: 100), clock: clock) { gmail in
            let wire = FakeGmailTransport(gmail)
            let factory = DefaultGmailClientFactory(apiTransport: wire,
                                                    config: GmailClientConfig(userAgent: "OpenHumanMail/test"),
                                                    clock: clock, metrics: { _ in metrics }) { _ in
                (StaticTokenProvider(), [GmailScope.modify])
            }
            wireBox = wire
            return try! factory.client(for: "me@example.com")
        }
        let wire = try #require(wireBox)
        let seeded = await h.gmail.seedMailbox(count: 200, end: testNow.addingTimeInterval(-3_600))
        try await h.syncer.sync(reason: "launch")
        #expect(await h.syncer.runBackfill() == .complete)
        #expect(try bodies(h) == BodyCounts(stored: seeded.messages, pending: 0, failed: 0))
        #expect(!wire.requests.isEmpty && wire.nonGETRequests.isEmpty)
        #expect(wire.requests.allSatisfy { $0.method == "GET" || ($0.method == "POST" && $0.url.path().hasPrefix("/batch/")) })
        let bodyUnits = await h.gmail.units(for: .getMessage)
        #expect(bodyUnits > 0 && bodyUnits % QuotaCost.units(.getMessage) == 0)
    }

    @Test func theGateReportsTheMostImportantHoldAndTheGracePeriod() {
        let reachable = Flag(true), constrained = Flag(false)
        let gate = BackfillGate(isReachable: { reachable.isOn }, isConstrained: { constrained.isOn })
        let now = testNow
        #expect(gate.hold(now: now) == nil)
        constrained.set(true)
        #expect(gate.hold(now: now) == .lowPower)
        gate.beginDraining()
        #expect(gate.hold(now: now) == .queueDrain)
        gate.beginInteractive()
        #expect(gate.hold(now: now) == .interactive)
        reachable.set(false)
        #expect(gate.hold(now: now) == .offline)
        reachable.set(true)
        gate.endInteractive(now: now)
        #expect(gate.hold(now: now.addingTimeInterval(1)) == .interactive)
        #expect(gate.hold(now: now.addingTimeInterval(4)) == .queueDrain)
        gate.endDraining()
        constrained.set(false)
        #expect(gate.hold(now: now.addingTimeInterval(4)) == nil)
    }

    @Test func statusTextOfTheSearchDownload() {
        var p = SyncProgress(stage: .searchBodies, isRunning: true, bodiesDone: 1_240, bodiesTotal: 19_000)
        #expect(p.statusText == "Downloading messages for search: 1,240 of 19,000")
        p.bodiesTotal = nil
        #expect(p.statusText == "Downloading messages for search: 1,240")
        p.hold = .lowPower
        #expect(p.statusText == "Message download paused to save power: 1,240")
        p.isRunning = false
        #expect(p.statusText == nil)
    }

    @Test func storeGrowthPerStoredBodyIsMeasuredFromFixtures() async throws {
        var rows: [String] = []
        for chars in [0, 4_000, 16_000] {
            let (bodies, bytes) = try await storeGrowth(bodyChars: chars, threads: 300)
            #expect(bodies > 100 && bytes > 0)
            rows.append("body \(chars == 0 ? "fixture (about 25 chars)" : "\(chars) chars"): \(bodies) bodies, +\(bytes) bytes, "
                        + "\(bytes / bodies) bytes each, \(Double(bytes) / Double(bodies) * 10_000 / 1_048_576) MiB per 10,000")
        }
        print("store growth:\n" + rows.joined(separator: "\n"))
    }

    private func storeGrowth(bodyChars: Int, threads: Int) async throws -> (bodies: Int, bytes: Int) {
        let clock = InstantClock(now: testNow)
        let settings = backfillSettings(pageSize: 500)
        let h = try SyncHarness(settings: settings, clock: clock, onDisk: true)
        let location = try #require(h.location)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func words(_ count: Int) -> String {
            var out = ""
            while out.count < count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let length = 3 + Int(seed >> 60) % 7
                var word = ""
                var x = seed
                for _ in 0..<length { word.append(Character(UnicodeScalar(97 + UInt8(x % 26)))); x /= 26 }
                out += word + " "
            }
            return String(out.prefix(count))
        }
        for n in 0..<threads {
            await h.gmail.deliver(subject: "Growth \(n)", body: bodyChars == 0 ? "Fixture body \(n)." : words(bodyChars),
                                  labels: ["INBOX"], date: testNow.addingTimeInterval(-3_600 - Double(threads - n) * 600))
        }
        try await h.syncer.sync(reason: "launch")
        let policy = Mutex(BodyDownloadPolicy(enabled: false))
        let syncer = AccountSyncer(account: h.account, store: h.store, api: h.gmail, clock: clock, settings: settings,
                                   bodyPolicy: { policy.withLock { $0 } })
        #expect(await syncer.runBackfill() == .complete)
        func fileBytes() throws -> Int {
            try h.store.runIdleMaintenance(force: true)
            let urls = [location.databaseURL, URL(fileURLWithPath: location.databaseURL.path + "-wal")]
            return urls.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
        }
        let before = (try bodies(h).stored, try fileBytes())
        policy.withLock { $0 = BodyDownloadPolicy() }
        await syncer.bodySettingsChanged()
        #expect(await syncer.runBackfill() == .complete)
        let after = (try bodies(h).stored, try fileBytes())
        return (after.0 - before.0, after.1 - before.1)
    }
}
