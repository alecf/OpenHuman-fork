import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1")) struct ImportanceTimingTests {
    private static let words = ["contract", "meeting", "budget", "pitch", "review", "quarterly", "launch", "invoice", "design",
                                "hiring", "roadmap", "customer", "support", "release", "travel", "lunch", "update", "metrics"]

    private func body(_ n: Int) -> String {
        var rng = ImportanceRNG(seed: UInt64(n + 1))
        var out = ""
        while out.utf8.count < 6_000 { out += rng.pick(Self.words) + " " }
        return out
    }

    @Test func replacing5000InboxThreadsStaysInBudget() throws {
        let f = try ImportanceFixture()
        try f.split("Pitches", "subject:pitch OR from:@startup.example")
        try f.split("News", "list:news OR from:@news.example")
        try f.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Clients", type: "user")],
                                 account: f.account, removeMissing: false)
        for batch in 0..<10 {
            try f.upsert((0..<500).map { i in
                let n = batch * 500 + i
                let labels = n % 7 == 0 ? ["INBOX", "IMPORTANT"] : (n % 11 == 0 ? ["INBOX", "Label_1", "UNREAD"] : ["INBOX"])
                let text = n % 10 < 3 ? body(n) : nil
                return .fixture("m\(n)", thread: "t\(n)", minutes: n, labels: labels,
                                from: "p\(n % 40)@corp\(n % 5).example", to: ["me@example.com"],
                                subject: n % 13 == 0 ? "Pitch \(n)" : "Subject \(n)", snippet: "snippet \(n)",
                                body: text.map { MessageBodyUpsert(text: $0, hasCalendarInvite: false, decodeWarnings: [], searchText: $0) })
            })
        }
        func measure(_ label: String, _ edit: () throws -> Void) throws -> Double {
            try edit()
            var samples: [Double] = []
            for _ in 0..<5 {
                let elapsed = try f.store.write { db -> Double in
                    let start = ContinuousClock.now
                    try ThreadAggregator.reevaluateSplits(account: f.account.rawValue, in: db)
                    let d = ContinuousClock.now - start
                    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                }
                samples.append(elapsed)
            }
            let sorted = samples.sorted()
            print("importance timing (\(label)): re-placing 5000 inbox threads: \(sorted.map { Int($0) }) ms")
            return sorted.last ?? 0
        }
        let plain = try measure("sender, domain and label rules") {
            for i in 0..<10 { try f.rule(.sender, "p\(i)@corp\(i % 5).example", i % 3 == 0 ? .neverImportant : .important) }
            for i in 0..<3 { try f.rule(.domain, "corp\(i).example") }
            try f.rule(.label, "Clients")
            try f.rule(.sender, "p7@corp2.example", .exemptFromSplit)
        }
        #expect(plain <= 50, "budget without text rules")
        let text = try measure("plus 5 keyword rules over bodies") {
            for word in ["contract", "invoice", "roadmap", "hiring", "zeppelin"] { try f.rule(.keyword, word) }
        }
        #expect(text <= 100, "budget with keyword rules")
        let counts = try f.store.importanceCounts(account: f.account)
        #expect(counts.important + counts.normal + counts.suppressed == 5000)
        try fullRebuildChangesNothing(f.store)
    }
}
