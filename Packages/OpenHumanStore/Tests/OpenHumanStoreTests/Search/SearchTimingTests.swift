import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct SearchTimingTests {
    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
    }

    @Test func twoTermSearchOverTwentyThousandMessages() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let vocabulary = 3_000
        for batch in 0..<100 {
            let messages = (0..<200).map { i -> MessageUpsert in
                let n = batch * 200 + i
                let text = (0..<60).map { "word\((n * 7 + $0 * 131) % vocabulary)x" }.joined(separator: " ")
                return .fixture("m\(n)", thread: "t\(n / 3)", minutes: n, labels: n % 5 == 0 ? ["INBOX", "UNREAD"] : ["INBOX"],
                                from: "sender\(n % 97)@example.com", subject: "topic\(n % 500)x topic\((n / 500) % 40)y \(n)",
                                snippet: "s", body: .fixture(html: nil, text: text))
            }
            _ = try store.upsertMessages(messages, account: account, generation: 1)
        }
        let queries = ["word17x word1203x", "word5x from:sender5@example.com", "word9x is:unread", "topic7x word44x", "ro", "-word3x word77x"]
        for text in queries {
            let query = try SearchParser.parse(text)
            var samples: [Double] = []
            for _ in 0..<15 { samples.append(try milliseconds { _ = try store.search(query, accounts: nil, after: nil, limit: 50) }) }
            samples.sort()
            print("timing: \(text) -> median \(Int(samples[7])) ms, p95 \(Int(samples[13])) ms (20,000 messages, in-memory, this build)")
            if text != "ro" { #expect(samples[13] <= 50, "\(text): budget 50 ms p95") }
        }
    }
}
