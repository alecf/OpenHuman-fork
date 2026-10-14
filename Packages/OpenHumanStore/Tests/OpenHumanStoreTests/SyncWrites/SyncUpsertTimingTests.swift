import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct SyncUpsertTimingTests {
    @Test func upsertOf200MetadataMessages() throws {
        let f = try AggregationFixture()
        try f.labels((0..<60).map { ("Label_\($0)", "Project \($0)") })
        for batch in 0..<10 {
            try f.upsert((0..<200).map { i in
                .fixture("bg\(batch)-\(i)", thread: "bg\((batch * 200 + i) % 600)", minutes: batch * 200 + i,
                         labels: i % 4 == 0 ? ["INBOX", "UNREAD", "Label_\(i % 60)"] : ["Label_\(i % 60)"],
                         from: "sender\(i % 37)@example.com")
            })
        }
        var samples: [Double] = []
        for round in 0..<7 {
            let batch = (0..<200).map { i in
                MessageUpsert.fixture("new\(round)-\(i)", thread: "nt\(round)-\(i / 4)", minutes: 10_000 + round * 200 + i,
                                      labels: ["INBOX", "UNREAD", i % 3 == 0 ? "IMPORTANT" : "CATEGORY_UPDATES"],
                                      from: "p\(i % 50)@example.com", fromName: "Person \(i % 50)")
            }
            let start = ContinuousClock.now
            try f.upsert(batch)
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2], worst = sorted.last ?? 0
        print("timing: upsert 200 metadata messages (50 threads, in-memory, this build): median \(Int(median)) ms, max \(Int(worst)) ms")
        #expect(median <= 60, "budget: 60 ms")
        #expect(try f.store.label(account: f.account, key: "INBOX")?.totalThreads ?? 0 > 350)
    }
}
