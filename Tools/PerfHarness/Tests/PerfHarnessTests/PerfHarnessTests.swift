import Foundation
import PerfHarnessKit
import Testing

@MainActor
@Suite(.serialized)
struct PerfHarnessTests {
    @Test func smokeRunKeepsTheTableConsistent() async throws {
        let harness = ListPerfHarness(options: .smoke)
        let report = try await harness.run()
        #expect(harness.problems.isEmpty, "\(harness.problems)")
        #expect(report.results.count >= 10)
        #expect(report.results.allSatisfy { $0.stats.count > 0 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1"))
    func fiftyThousandThreadsWithinBudget() async throws {
        let harness = ListPerfHarness()
        let report = try await harness.run()
        print(report.text)
        if let path = ProcessInfo.processInfo.environment["OPENHUMAN_PERF_REPORT"] {
            try report.text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(harness.problems.isEmpty, "\(harness.problems)")
        #expect(report.failures.isEmpty, "\(report.failures)")
    }
}
