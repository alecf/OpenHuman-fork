import Foundation
import OpenHumanStore
import Synchronization

enum PerfEnvironment {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1" }
    static var enforce: Bool { ProcessInfo.processInfo.environment["OPENHUMAN_PERF_ENFORCE"] == "1" }
    static var corpusName: String { ProcessInfo.processInfo.environment["OPENHUMAN_PERF_CORPUS"] ?? "perf" }
    static var reportPath: String? { ProcessInfo.processInfo.environment["OPENHUMAN_PERF_REPORT"] }
    #if DEBUG
    static let buildKind = "debug"
    #else
    static let buildKind = "release"
    #endif
}

struct Sample {
    var name: String
    var budgetMs: Double?
    var millis: [Double]

    var p50: Double { percentile(0.5) }
    var p95: Double { percentile(0.95) }
    var max: Double { millis.max() ?? 0 }

    func percentile(_ p: Double) -> Double {
        let sorted = millis.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * p).rounded(.up))
        return sorted[Swift.min(sorted.count - 1, Swift.max(0, rank - 1))]
    }

    var withinBudget: Bool { budgetMs.map { p95 <= $0 } ?? true }
}

func milliseconds(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func measure(_ name: String, budgetMs: Double?, samples: Int, warmup: Int = 3, _ body: (Int) throws -> Void) rethrows -> Sample {
    for i in 0..<warmup { try body(-1 - i) }
    var out: [Double] = []
    out.reserveCapacity(samples)
    let clock = ContinuousClock()
    for i in 0..<samples { out.append(milliseconds(try clock.measure { try body(i) })) }
    return Sample(name: name, budgetMs: budgetMs, millis: out)
}

struct PerfReport {
    var samples: [Sample] = []
    var notes: [String] = []

    mutating func add(_ sample: Sample) { samples.append(sample) }

    func render(header: [String]) -> String {
        var out = ["", "=== OpenHumanStore performance report ==="]
        out += header
        out.append("")
        let width = (samples.map(\.name.count).max() ?? 10) + 2
        func pad(_ s: String) -> String { s + String(repeating: " ", count: Swift.max(0, width - s.count)) }
        out.append(pad("operation") + "n      p50 ms    p95 ms    max ms  budget ms  result")
        for s in samples {
            let budget = s.budgetMs.map { String(format: "%9.1f", $0) } ?? "        -"
            let verdict = s.budgetMs == nil ? "info" : (s.withinBudget ? "ok" : "OVER")
            out.append(pad(s.name) + String(format: "%-5d %9.3f %9.3f %9.3f", s.millis.count, s.p50, s.p95, s.max) + " " + budget + "  " + verdict)
        }
        if !notes.isEmpty { out.append(""); out += notes.map { "note: " + $0 } }
        out.append("")
        return out.joined(separator: "\n")
    }
}

final class PerfCollector<Value: Sendable & Equatable>: Sendable {
    private final class Box: Sendable { let values = Mutex<[Value]>([]) }
    private let box = Box()
    private let task: Task<Void, Never>

    init(_ observation: StoreObservation<Value>) {
        let box = self.box
        let stream = observation.values()
        task = Task { do { for try await v in stream { box.values.withLock { $0.append(v) } } } catch {} }
    }

    var values: [Value] { box.values.withLock { $0 } }

    func wait(timeout: Duration = .seconds(15), until condition: ([Value]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(values) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition(values)
    }

    func stop() { task.cancel() }
}

final class PerfProcessExit: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    func attach(to process: Process) { process.terminationHandler = { [done] _ in done.signal() } }
    func wait(_ process: Process, timeout: TimeInterval) -> Bool {
        if done.wait(timeout: .now() + timeout) == .success { return true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return false
    }
}
