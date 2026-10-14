import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct GroundTruthTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func seeded() async -> (FakeGmail, [String]) {
        let gmail = FakeGmail(clock: InstantClock())
        let projects = await gmail.addUserLabel("Projects Zebra")
        var threads: [String] = []
        for n in 0..<6 {
            threads.append(await gmail.deliver(from: "Carol Secret <carol.secret@example.com>",
                                               subject: "Zebra subject \(n)", body: "Zebra body \(n)").threadID)
        }
        await gmail.deliver(subject: "Zebra reply", body: "Zebra reply body", threadID: threads[2])
        await gmail.modifyLabels(messageID: threads[1], add: ["STARRED", projects], remove: ["UNREAD"])
        await gmail.deliver(subject: "Zebra sent", body: "x", labels: ["SENT"])
        return (gmail, threads)
    }

    @Test func snapshotThroughTheReadOnlyStackSendsOnlyGETsAndMatchesTheFake() async throws {
        let (gmail, threads) = await seeded()
        let direct = try await GroundTruth.snapshot(api: gmail, sampleThreads: 4, now: now)

        let clock = InstantClock()
        let wire = FakeGmailTransport(gmail)
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(),
                                 transport: ReadOnlyTransport(wrapping: wire), config: GmailClientConfig(userAgent: "t"),
                                 clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                                 jitter: { 0 })
        let viaREST = try await GroundTruth.snapshot(api: client, sampleThreads: 4, now: now)
        #expect(viaREST == direct)
        #expect(!wire.requests.isEmpty && wire.nonGETRequests.isEmpty)
        let batches = wire.requests.filter { $0.url.path().hasPrefix("/batch/") }
        let batchText = String(decoding: batches.first?.body ?? Data(), as: UTF8.self)
        let threadGets = batchText.components(separatedBy: "\r\n").filter { $0.hasPrefix("GET /gmail/v1/users/me/threads/") }
        #expect(batches.count == 1 && threadGets.count == 4 && threadGets.allSatisfy { $0.contains("?format=minimal ") })

        let projects = try #require(await gmail.labelID(named: "Projects Zebra"))
        #expect(Set(direct.labels.keys) == Set(GroundTruth.defaultLabels + [projects]))
        #expect(direct.labels["INBOX"]?.threadsTotal == 6 && direct.labels["STARRED"]?.threadsTotal == 1)
        #expect(direct.labels[projects]?.messagesTotal == 1)
        #expect(direct.inboxThreadIDs == [threads[2], threads[5], threads[4], threads[3]])
        #expect(Set(direct.threads.keys) == Set(direct.inboxThreadIDs))
        #expect(direct.threads[threads[2]]?.messages.count == 2)
        let newest = try #require(direct.threads[threads[5]]?.messages.first)
        #expect(newest.id == threads[5] && newest.labelHash == GroundTruth.labelHash(["UNREAD", "INBOX"]))
        #expect(direct.accountHash == WriteAllowlist.accountHash("me@example.com"))

        let text = String(decoding: try JSONEncoder().encode(direct), as: UTF8.self)
        for secret in ["Zebra", "Carol", "carol.secret", "example.com", "Projects"] {
            #expect(!text.contains(secret), "\(secret)")
        }
    }

    @Test func explicitLabelsAndPaging() async throws {
        let (gmail, _) = await seeded()
        let snapshot = try await GroundTruth.snapshot(api: gmail, labels: ["INBOX"], sampleThreads: 0, now: now)
        #expect(Array(snapshot.labels.keys) == ["INBOX"] && snapshot.inboxThreadIDs.isEmpty && snapshot.threads.isEmpty)
        await gmail.seedInbox(count: 600)
        let big = try await GroundTruth.snapshot(api: gmail, labels: [], sampleThreads: 550, now: now)
        #expect(big.inboxThreadIDs.count == 550 && Set(big.inboxThreadIDs).count == 550)
    }

    @Test func labelHashIsOrderAndDuplicateFree() {
        #expect(GroundTruth.labelHash(["INBOX", "UNREAD"]) == GroundTruth.labelHash(["UNREAD", "INBOX", "INBOX"]))
        #expect(GroundTruth.labelHash(["INBOX"]) != GroundTruth.labelHash(["INBOX", "UNREAD"]))
        #expect(GroundTruth.labelHash([]).count == 64)
    }
}
