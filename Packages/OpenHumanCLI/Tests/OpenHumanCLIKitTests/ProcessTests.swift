import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import Testing
@testable import OpenHumanCLIKit

struct ChildResult { var code: Int32; var out: String; var err: String; var seconds: Double }

private final class BundleMarker {}

enum ChildProcess {
    static func binary(file: String = #filePath) -> URL? {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        var candidates = [build.appendingPathComponent("debug/openhuman"), build.appendingPathComponent("release/openhuman")]
        candidates.append(Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("openhuman"))
        for triple in (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [] {
            candidates.append(build.appendingPathComponent("\(triple)/debug/openhuman"))
            candidates.append(build.appendingPathComponent("\(triple)/release/openhuman"))
        }
        let found = candidates.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        return found.max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func run(_ arguments: [String], environment: [String: String], timeout: TimeInterval = 120) throws -> ChildResult {
        let exe = try #require(binary(), "the openhuman executable was not built next to the tests")
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let outData = Locked(Data()), errData = Locked(Data())
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; outData.withLock { $0.append(d) } }
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; errData.withLock { $0.append(d) } }
        let started = Date()
        try process.run()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            Issue.record("openhuman \(arguments.prefix(2)) did not exit within \(timeout) s")
        }
        let seconds = Date().timeIntervalSince(started)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outData.withLock { $0.append(out.fileHandleForReading.readDataToEndOfFile()) }
        errData.withLock { $0.append(err.fileHandleForReading.readDataToEndOfFile()) }
        return ChildResult(code: process.terminationStatus, out: String(decoding: outData.withLock { $0 }, as: UTF8.self),
                           err: String(decoding: errData.withLock { $0 }, as: UTF8.self), seconds: seconds)
    }
}

@Suite struct ProcessTests {
    func environment(_ h: Harness, _ extra: [String: String] = [:]) -> [String: String] {
        ["OPENHUMAN_HOME": h.directory.path, "OPENHUMAN_STORE_NOTIFICATION": h.notification, "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()].merging(extra) { $1 }
    }

    @Test func exitCodesAndStreamsOfTheRealExecutable() throws {
        let h = try Harness()
        try h.store.close()
        let inbox = try ChildProcess.run(["gmail", "inbox", "--max", "1"], environment: environment(h))
        #expect(inbox.code == 0)
        let json = try #require(JSONSerialization.jsonObject(with: Data(inbox.out.utf8)) as? [String: Any])
        #expect(json["ok"] as? Bool == true && json["command"] as? String == "gmail.inbox")
        #expect(inbox.err.contains("warning:"))

        let send = try ChildProcess.run(["gmail", "send", "--to", "a@example.com"], environment: environment(h))
        #expect(send.code == 5 && send.out.contains("send_not_supported"))
        let usage = try ChildProcess.run(["gmail", "bogus"], environment: environment(h))
        #expect(usage.code == 2)
        let refused = try ChildProcess.run(["gmail", "done", "t1"], environment: environment(h))
        #expect(refused.code == 5 && refused.out.contains("mail_changes_in_app"))
        let missing = try ChildProcess.run(["gmail", "inbox", "--home", h.directory.appendingPathComponent("nope").path], environment: environment(h))
        #expect(missing.code == 4)
        let help = try ChildProcess.run(["--help"], environment: environment(h))
        #expect(help.code == 0 && help.out.contains("SUBCOMMANDS"))
    }

    @Test func aLiveOwnerInAnotherProcessMeansWaitThenExit6() throws {
        let h = try Harness()
        try h.holdLease()
        let draft = try ChildProcess.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x",
                                          "--wait", "--timeout", "2s"], environment: environment(h))
        #expect(draft.code == 6)
        #expect(draft.seconds >= 1.5, "it waited for the app: \(draft.seconds)")
        #expect(!draft.err.contains("not running"))
        let ops = try h.operations()
        #expect(ops.map(\.kind) == [.upsertDraft])
        #expect(try h.store.drafts(account: h.account, states: [], limit: 10).first?.origin == .cli)
        let json = try #require(JSONSerialization.jsonObject(with: Data(draft.out.utf8)) as? [String: Any])
        #expect((json["data"] as? [String: Any])?["status"] as? String == "queued")
    }

    @Test func withNoOwnerWritesExit6AtOnceAndThereIsNoNetwork() throws {
        let h = try Harness()
        let write = environment(h)
        let done = try ChildProcess.run(["gmail", "archive", "t1", "--wait", "--timeout", "3600s"], environment: write)
        #expect(done.code == 5 && done.out.contains("mail_changes_in_app"))
        #expect(done.err.contains("Make mail changes in OpenHuman Mail."))
        let draft = try ChildProcess.run(["gmail", "drafts", "create", "--to", "a@example.com", "--subject", "S", "--body", "x",
                                          "--wait", "--timeout", "3600s"], environment: write)
        #expect(draft.code == 6)
        #expect(draft.err.contains("Saved locally. OpenHuman Mail adds it to your Gmail Drafts for review when it runs."))
        #expect(!draft.err.contains("within the timeout"))
        #expect(try h.operations().count == 1)
    }

    @Test func warmInboxStartupBudget() throws {
        guard ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1" else { return }
        let h = try Harness()
        try h.store.close()
        let env = environment(h)
        _ = try ChildProcess.run(["gmail", "inbox", "--json", "--quiet"], environment: env)
        var times: [Double] = []
        for _ in 0..<7 { times.append(try ChildProcess.run(["gmail", "inbox", "--json", "--quiet"], environment: env).seconds) }
        let median = times.sorted()[times.count / 2]
        print("PERF gmail inbox --json median \(Int(median * 1000)) ms over \(times.count) runs")
        #expect(median < 0.080, "median \(median * 1000) ms (budget: < 80 ms warm, release build)")
    }
}
