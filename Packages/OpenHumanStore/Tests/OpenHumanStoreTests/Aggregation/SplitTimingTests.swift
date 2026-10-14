import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct SplitTimingTests {
    @Test func reevaluating5000InboxThreads() throws {
        let f = try AggregationFixture()
        for batch in 0..<10 {
            try f.upsert((0..<500).map { i in
                let n = batch * 500 + i
                return .fixture("m\(n)", thread: "t\(n)", minutes: n, labels: n % 7 == 0 ? ["INBOX", "IMPORTANT"] : ["INBOX"],
                                from: "p\(n % 40)@corp\(n % 3).example", to: ["me@example.com", "team\(n % 9)@example.com"])
            })
        }
        let rules: [SplitRule] = [.or([.from("corp1.example"), .to("team3@example.com")]), .isImportant,
                                  .and([.not(.isImportant), .from("@corp2.example")])]
        var samples: [Double] = []
        var moved = 0
        for rule in rules {
            let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
            let elapsed = try f.store.write { db -> Double in
                try db.execute(sql: "UPDATE splits SET rule_json = ? WHERE account_id = ?", arguments: [json, f.account.rawValue])
                let start = ContinuousClock.now
                moved += try ThreadAggregator.reevaluateSplits(account: f.account.rawValue, in: db)
                let d = ContinuousClock.now - start
                return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            }
            samples.append(elapsed)
        }
        let worst = samples.max() ?? 0
        print("timing: split re-evaluation of 5000 inbox threads (this build): \(samples.map { Int($0) }) ms")
        #expect(worst <= 50, "budget")
        #expect(moved > 0)
        let other = try #require(try f.store.label(account: f.account, key: "oh:split:other"))
        let inbox = try #require(try f.store.label(account: f.account, key: "INBOX"))
        let splitTotal = try f.store.read { db in
            try Int.fetchOne(db, sql: "SELECT sum(total_threads) FROM labels WHERE kind = 'split'") ?? 0
        }
        #expect(inbox.totalThreads == 5000 && splitTotal == 5000 && other.totalThreads < 5000)
    }
}
