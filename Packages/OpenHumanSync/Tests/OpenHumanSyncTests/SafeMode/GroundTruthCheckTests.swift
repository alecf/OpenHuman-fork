import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct GroundTruthCheckTests {
    private let secrets = ["Zebra", "Carol", "carol.secret", "example.com", "Projects", "Late"]

    private func seed(_ h: SyncHarness) async -> (threads: [String], projects: String) {
        let projects = await h.gmail.addUserLabel("Projects Zebra")
        var threads: [String] = []
        for n in 0..<8 {
            threads.append(await h.gmail.deliver(from: "Carol Secret <carol.secret@example.com>",
                                                 subject: "Zebra subject \(n)", body: "Zebra body \(n)").threadID)
        }
        await h.gmail.deliver(from: "Carol Secret <carol.secret@example.com>", subject: "Zebra reply",
                              body: "Zebra reply body", threadID: threads[3])
        await h.gmail.modifyLabels(messageID: threads[1], add: ["STARRED", projects], remove: ["UNREAD"])
        return (threads, projects)
    }

    @Test func syncedMailboxIsCleanAndOneLabelChangeIsReportedByID() async throws {
        let h = try SyncHarness(onDisk: true)
        let (threads, projects) = await seed(h)
        try await h.syncer.sync(reason: "launch")

        let snapshot = try await GroundTruth.snapshot(api: h.gmail, sampleThreads: 50, now: testNow)
        let clean = try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: snapshot, now: testNow)
        #expect(clean.isClean, "\(clean)")
        #expect(clean.labelsCompared == GroundTruth.defaultLabels.count + 1 && clean.inboxThreadsCompared == 8)
        #expect(clean.gmailCounts[projects]?.threadsTotal == 1)

        await h.gmail.modifyLabels(messageID: threads[5], add: ["STARRED"])
        let changed = try await GroundTruth.snapshot(api: h.gmail, sampleThreads: 50, now: testNow)
        let report = try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: changed, now: testNow)
        #expect(report.threadMismatches == [.init(threadID: threads[5], labelMismatches: [threads[5]])])
        #expect(report.countMismatches == [.init(labelID: "STARRED", field: "threadsTotal", gmail: 2, store: 1),
                                           .init(labelID: "STARRED", field: "threadsUnread", gmail: 1, store: 0)])
        #expect(report.inboxOnlyInGmail.isEmpty && report.inboxOnlyInStore.isEmpty)

        try await h.syncer.sync(reason: "poll")
        let resynced = try await GroundTruth.snapshot(api: h.gmail, sampleThreads: 50, now: testNow)
        #expect(try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: resynced, now: testNow).isClean)

        let late = await h.gmail.addUserLabel("Late Zebra")
        let newThread = await h.gmail.deliver(from: "Carol Secret <carol.secret@example.com>", subject: "Zebra new",
                                              body: "Zebra new body").threadID
        let ahead = try await GroundTruth.snapshot(api: h.gmail, sampleThreads: 50, now: testNow)
        let behind = try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: ahead, now: testNow)
        #expect(behind.inboxOnlyInGmail == [newThread])
        #expect(behind.threadMismatches == [.init(threadID: newThread, missingInStore: true, messagesOnlyInGmail: [newThread])])
        #expect(behind.countMismatches.contains(.init(labelID: late, field: "label missing in store", gmail: 0)))
        #expect(behind.countMismatches.contains(.init(labelID: "INBOX", field: "threadsTotal", gmail: 9, store: 8)))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oh-gt-\(UUID().uuidString)")
        let file = try GroundTruthCheck.write(behind, storeDirectory: directory)
        #expect(file.deletingLastPathComponent().lastPathComponent == "Logs")
        #expect(file.lastPathComponent == "ground-truth-20260921T141320Z.json")
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        let encoded = String(decoding: try JSONEncoder().encode(behind), as: UTF8.self)
        for text in [onDisk, encoded] {
            for secret in secrets { #expect(!text.contains(secret), "\(secret)") }
            #expect(text.contains(newThread))
        }
        let decoded = try { () throws -> GroundTruthReport in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(GroundTruthReport.self, from: Data(onDisk.utf8))
        }()
        #expect(decoded == behind)
    }

    @Test func aSnapshotOfAnotherAccountIsRefused() async throws {
        let h = try SyncHarness()
        _ = await seed(h)
        try await h.syncer.sync(reason: "launch")
        var snapshot = try await GroundTruth.snapshot(api: h.gmail, sampleThreads: 5, now: testNow)
        snapshot.accountHash = WriteAllowlist.accountHash("someone-else@example.com")
        #expect(throws: GroundTruthCheck.Failure.accountMismatch) {
            _ = try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: snapshot)
        }
    }
}
