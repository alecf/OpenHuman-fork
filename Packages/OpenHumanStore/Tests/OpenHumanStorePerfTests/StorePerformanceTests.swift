import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.serialized) struct StorePerformanceTests {
    private static func config() -> SyntheticCorpus.Config {
        switch PerfEnvironment.corpusName {
        case "small": return .small
        case "spec": return .spec
        default: return .perf
        }
    }

    private enum Budget {
        static let open = 30.0, page = 2.0, window = 15.0, detail = 3.0, body = 2.0, counts = 1.0, archive = 5.0, upsert = 60.0
        static let search = 50.0
        static let sizeGB = 2.5
        static let wakeNotify = 200.0
    }

    @Test(.enabled(if: PerfEnvironment.enabled)) func budgets() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let location = StoreLocation(directory: dir)
        func open(readOnly: Bool = false, observe: Bool = false) throws -> MailStore {
            try MailStore.open(StoreOptions(location: location, processKind: .app, readOnly: readOnly,
                                            observeExternalChanges: observe, appVersion: "perf"))
        }
        var report = PerfReport()

        var store = try open()
        let config = Self.config()
        let started = ContinuousClock.now
        let corpus = try SyntheticCorpus.generate(config, in: store)
        let generation = ContinuousClock.now - started
        try store.write { try $0.execute(sql: "ANALYZE") }
        try store.close()
        store = try open(observe: true)
        let account = corpus.accounts[0]

        report.add(try measure("open + migrations check", budgetMs: Budget.open, samples: 15) { _ in
            try open(readOnly: true).close()
        })

        let userLabel = try #require(corpus.userLabelIDs.first)
        let views: [MailboxView] = [.system(account, .inbox), .system(account, .allMail), .system(account, .sent),
                                    .label(account, userLabel), .splitOther(account), .system(account, .starred)]
        var depthCursors: [ThreadCursor?] = [nil]
        var cursor: ThreadCursor?
        for _ in 0..<40 {
            guard let next = try store.threadPage(view: .system(account, .allMail), after: cursor, limit: 500).nextCursor else { break }
            cursor = next
            depthCursors.append(next)
        }
        report.add(try measure("threadPage 50, six views, first page", budgetMs: Budget.page, samples: 300) { i in
            _ = try store.threadPage(view: views[abs(i) % views.count], after: nil, limit: 50)
        })
        report.add(try measure("threadPage 50, All Mail, \(depthCursors.count) depths", budgetMs: Budget.page, samples: 300) { i in
            _ = try store.threadPage(view: .system(account, .allMail), after: depthCursors[abs(i) % depthCursors.count], limit: 50)
        })

        report.add(try measure("live window 2000 rows re-fetch", budgetMs: Budget.window, samples: 30) { _ in
            let window = try store.read { try MailStore.window(view: .system(account, .allMail), limit: 2000, in: $0) }
            if window.items.count < 2000 && window.totalCount >= 2000 { Issue.record("window short: \(window.items.count)") }
        })

        if let big = corpus.thirtyMessageThread, let ref = try store.thread(account: big.account, gmailThreadID: big.gmailThreadID) {
            report.add(try measure("threadDetail 30 messages", budgetMs: Budget.detail, samples: 150) { _ in
                let detail = try store.threadDetail(ref.rowID)
                if detail?.messages.count != 30 { Issue.record("detail has \(detail?.messages.count ?? -1) messages") }
            })
        } else { report.notes.append("no 30-message thread in this corpus; threadDetail not measured") }
        var bodyIDs: [MessageRowID] = []
        for probe in corpus.messagesWithBody.prefix(300) {
            if let m = try store.message(account: probe.account, gmailMessageID: probe.gmailMessageID) { bodyIDs.append(m.id) }
        }
        if !bodyIDs.isEmpty {
            report.add(try measure("body", budgetMs: Budget.body, samples: 300) { i in _ = try store.body(bodyIDs[abs(i) % bodyIDs.count]) })
        }

        report.add(try measure("counts", budgetMs: Budget.counts, samples: 300) { _ in _ = try store.counts(account: account) })

        let inbox = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 100).items
        if inbox.count >= 80 {
            report.add(try measure("archive 1 thread (apply action)", budgetMs: Budget.archive, samples: 50, warmup: 5) { i in
                _ = try store.apply(.archive([inbox[i >= 0 ? 10 + i : 9 + (-i) + 50].ref]), origin: .app)
            })
        } else { report.notes.append("fewer than 80 inbox threads; archive not measured") }

        var seq = 0
        report.add(try measure("sync upsert 200 messages (metadata)", budgetMs: Budget.upsert, samples: 15, warmup: 2) { _ in
            let batch = (0..<200).map { _ -> MessageUpsert in
                seq += 1
                return .fixture("perf-up-\(seq)", thread: "perf-up-t\(seq / 2)", minutes: -seq, labels: ["INBOX"],
                                history: 2_000_000_000 + UInt64(seq))
            }
            _ = try store.upsertMessages(batch, account: account, generation: 1)
        })

        report.notes.append("search, 2 free-text terms (budget \(Budget.search) ms): not measured here; the search tests time it")

        if let helper = Self.helperPath() {
            report.add(try await Self.wakeLatency(store: store, account: account, dir: dir, helper: helper, label: "notify", pollOnly: false, budgetMs: Budget.wakeNotify))
            report.add(try await Self.wakeLatency(store: store, account: account, dir: dir, helper: helper, label: "poll fallback only", pollOnly: true, budgetMs: 1500))
        } else { report.notes.append("ohstore-helper not found next to the test bundle: cross-process wake latency not measured") }

        try store.close()
        let sizes = Self.fileSizes(in: dir)
        report.notes.append(String(format: "database: %.1f MB main file (+ %.1f MB wal/shm), %.0f bytes per message; the 300k-message corpus is budgeted at %.1f GB; FTS is inside the main file",
                                   Double(sizes.db) / 1_048_576, Double(sizes.other) / 1_048_576,
                                   Double(sizes.db) / Double(corpus.messageCount), Budget.sizeGB))

        let header = [
            "build: \(PerfEnvironment.buildKind) (budgets are for release builds on Apple silicon)",
            "corpus: \(PerfEnvironment.corpusName): \(corpus.accounts.count) accounts, \(corpus.threadCount) threads, \(corpus.messageCount) messages, 30% with bodies, seed \(config.seed)",
            "generation: \(generation)",
            "host: \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        let text = report.render(header: header)
        print(text)
        if let path = PerfEnvironment.reportPath { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
        if PerfEnvironment.enforce {
            for s in report.samples where !s.withinBudget { Issue.record("over budget: \(s.name) p95 \(s.p95) ms > \(s.budgetMs ?? 0) ms") }
        }
    }

    private static func wakeLatency(store: MailStore, account: AccountID, dir: URL, helper: String, label: String,
                                    pollOnly: Bool, budgetMs: Double) async throws -> Sample {
        try store.close()
        if pollOnly { setenv("OPENHUMAN_STORE_POLL_ONLY", "1", 1) }
        let observer = try MailStore.open(StoreOptions(location: StoreLocation(directory: dir), processKind: .app,
                                                       observeExternalChanges: true, appVersion: "perf"))
        unsetenv("OPENHUMAN_STORE_POLL_ONLY")
        defer { try? observer.close() }
        let list = PerfCollector(observer.observeThreadList(view: .system(account, .inbox), limit: 100))
        _ = await list.wait { !$0.isEmpty }
        var latencies: [Double] = []
        for k in 0..<5 {
            guard let current = list.values.last, current.items.count > 3 else { break }
            let victim = current.items[k % 3].ref
            let before = list.values.count
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["write-archive", dir.path, String(victim.rowID.rawValue)]
            let out = Pipe()
            process.standardOutput = out
            let exit = PerfProcessExit()
            exit.attach(to: process)
            try process.run()
            let watchdog = DispatchWorkItem { [process] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            var seen = ""
            while !seen.contains("ready") {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                seen += String(decoding: chunk, as: UTF8.self)
            }
            let committed = ContinuousClock.now
            _ = await list.wait(timeout: .seconds(10)) { $0.count > before }
            latencies.append(milliseconds(ContinuousClock.now - committed))
            watchdog.cancel()
            if !exit.wait(process, timeout: 30) { Issue.record("ohstore-helper did not exit within 30 s; killed") }
        }
        list.stop()
        return Sample(name: "observer wake after another process commits (\(label))", budgetMs: budgetMs, millis: latencies)
    }

    @Test(.enabled(if: PerfEnvironment.enabled && PerfEnvironment.corpusName != "small")) func hotQueryPlansHoldOnTheBigCorpus() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-perf-plan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: dir), processKind: .test, appVersion: "perf"))
        _ = try SyntheticCorpus.generate(Self.config(), in: store)
        try store.write { try $0.execute(sql: "ANALYZE") }
        func plan(_ sql: String) throws -> String {
            try store.read { db in
                let st = try db.makeStatement(sql: "EXPLAIN QUERY PLAN " + sql)
                st.setUncheckedArguments(StatementArguments(Array(repeating: 1, count: 40)))
                return try Row.fetchAll(st).map { $0["detail"] as String }.joined(separator: "\n")
            }
        }
        let page = try plan("""
            SELECT \(MailStore.listColumns), tl.sort_at, tl.unread FROM thread_labels AS tl JOIN threads AS t ON t.tid = tl.tid
            WHERE tl.label_rid = ? AND (tl.sort_at, tl.tid) < (?, ?) ORDER BY tl.sort_at DESC, tl.tid DESC LIMIT 51
            """)
        #expect(page.contains("SEARCH tl USING PRIMARY KEY") && page.contains("SEARCH t USING INTEGER PRIMARY KEY") && !page.contains("TEMP B-TREE"), "\(page)")
        let detail = try plan("SELECT * FROM messages WHERE tid = ? ORDER BY internal_date ASC, mid ASC")
        #expect(detail.contains("messages_by_thread") && !detail.contains("TEMP B-TREE"), "\(detail)")
        let attachments = try plan("SELECT * FROM attachments WHERE mid IN (?, ?, ?, ?, ?)")
        #expect(!attachments.contains("SCAN attachments"), "\(attachments)")
        let from = try plan("""
            SELECT tid, internal_date FROM messages WHERE account_id = 1 AND from_email = 'x@example.com' AND in_trash = 0
            ORDER BY internal_date DESC LIMIT 500
            """)
        #expect(from.contains("messages_by_from") && !from.contains("TEMP B-TREE"), "\(from)")
        try store.close()
    }

    private static func fileSizes(in dir: URL) -> (db: Int, other: Int) {
        var db = 0, other = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            if name == "mail.sqlite" { db += size } else if name.hasPrefix("mail.sqlite") { other += size }
        }
        return (db, other)
    }

    private static func helperPath() -> String? {
        var candidates: [URL] = Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for relative in [".build/out/Products/Debug", ".build/debug", ".build/arm64-apple-macosx/debug", ".build/release", ".build/arm64-apple-macosx/release"] {
            candidates.append(root.appendingPathComponent(relative))
        }
        return candidates.map { $0.appendingPathComponent("ohstore-helper").path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
