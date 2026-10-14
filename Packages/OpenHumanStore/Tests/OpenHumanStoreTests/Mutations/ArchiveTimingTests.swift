import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct ArchiveTimingTests {
    @Test func archiveOneThread() throws {
        let f = try MutationFixture()
        try f.labels((0..<60).map { ("Label_\($0)", "Project \($0)") })
        for batch in 0..<30 {
            try f.upsert((0..<600).map { i in
                let n = batch * 600 + i
                return .fixture("m\(n)", thread: "t\(n / 3)", minutes: n,
                                labels: (n / 3) % 2 == 0 ? ["INBOX", "UNREAD", "Label_\(n % 60)"] : ["Label_\(n % 60)"],
                                from: "sender\(n % 37)@example.com")
            })
        }
        var samples: [Double] = []
        for k in 0..<200 {
            let ref = try f.ref("t\(k * 2)")
            let start = ContinuousClock.now
            _ = try f.store.apply(.archive([ref]), origin: .app)
            let d = ContinuousClock.now - start
            samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100]
        print("timing: archive 1 thread (in-memory, this build): median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms")
        #expect(p95 <= 5, "budget: 5 ms p95")
    }
}
