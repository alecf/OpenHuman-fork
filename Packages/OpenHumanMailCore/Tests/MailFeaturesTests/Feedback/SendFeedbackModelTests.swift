import Foundation
import MailModel
import Testing
@testable import MailFeatures

final class FakeTailscale: TailscaleRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var statusResult: Result<TailscaleRunResult, TailscaleRunError> = .success(TailscaleRunResult(exitCode: 0, output: TailscaleFixtures.status()))
    var sendResult: Result<TailscaleRunResult, TailscaleRunError> = .success(TailscaleRunResult(exitCode: 0))
    private var _sentBytes: Data?

    var calls: [[String]] { lock.withLock { _calls } }
    var sentBytes: Data? { lock.withLock { _sentBytes } }

    func run(arguments: [String], timeout: Duration) async throws -> TailscaleRunResult {
        lock.withLock { _calls.append(arguments) }
        if arguments == TaildropArguments.statusArguments { return try statusResult.get() }
        if arguments.first == "file", let path = arguments.dropFirst(3).first {
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            lock.withLock { _sentBytes = data }
        }
        return try sendResult.get()
    }
}

@MainActor
final class FakeContributor: FeedbackContributor {
    let id = "conversationDebug"
    let title = "Include this conversation's debug info"
    let isOnByDefault = false
    let containsEmailContent = false
    func attachments() async -> [FeedbackAttachment] { [FeedbackAttachment(name: "debug.txt", data: Data("debug".utf8))] }
}

@MainActor
struct SendFeedbackModelTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oh-send-feedback-\(UUID().uuidString)", isDirectory: true)

    final class Recorder: @unchecked Sendable {
        var saved: [String] = []
        var shared: [URL] = []
        var chosen: URL?
        var savedDevice = ""
    }

    func make(_ runner: FakeTailscale?, recorder: Recorder = Recorder(), screenshot: Data? = nil, thread: FeedbackThreadHeader? = nil,
              contributors: [any FeedbackContributor] = []) throws -> SendFeedbackModel {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zipOfDiagnostics: Data = {
            var zip = ZipArchive()
            zip.add(name: "log.txt", text: "ok line\nmail to leak@example.com\n")
            zip.add(name: "diagnostics.json", text: "{}")
            return zip.data()
        }()
        return SendFeedbackModel(SendFeedbackDependencies(
            runner: runner, now: { FeedbackBundlerTests.now }, appInfo: { FeedbackBundlerTests.app }, accountCount: { 2 },
            diagnostics: { zipOfDiagnostics }, screenshot: { screenshot }, thread: { thread }, contributors: contributors,
            savedDevice: { recorder.savedDevice }, saveDevice: { recorder.savedDevice = $0 },
            chooseSaveLocation: { name in recorder.chosen ?? self.root.appendingPathComponent(name) },
            share: { recorder.shared.append($0) }, temporaryRoot: root, statusTimeout: .seconds(1), sendTimeout: .seconds(1)))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test func loadsDevicesAndPicksTheRememberedOne() async throws {
        defer { cleanUp() }
        let recorder = Recorder()
        recorder.savedDevice = "studio"
        let model = try make(FakeTailscale(), recorder: recorder)
        #expect(model.deviceState == .loading)
        await model.load()
        #expect(model.deviceState == .ready)
        #expect(model.devices.map(\.target) == ["mac-mini", "studio"])
        #expect(model.selectedDevice == "studio")
    }

    @Test func choosingADeviceRemembersIt() async throws {
        defer { cleanUp() }
        let recorder = Recorder()
        let model = try make(FakeTailscale(), recorder: recorder)
        await model.load()
        #expect(model.selectedDevice == nil, "two devices and nothing remembered: the user chooses")
        model.selectedDevice = "mac-mini"
        #expect(recorder.savedDevice == "mac-mini")
    }

    @Test func nothingIsRunAfterTheStatusReadUntilSend() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        let model = try make(runner)
        await model.load()
        model.selectedDevice = "mac-mini"
        #expect(runner.calls == [TaildropArguments.statusArguments], "only the status read, which lists names")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func sendsTheZipThroughAFixedArrayAndDeletesTheTemporaryFolder() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        let model = try make(runner)
        await model.load()
        model.selectedDevice = "mac-mini"
        model.note = "it froze"
        await model.send()
        #expect(model.phase == .sent(device: "Mac mini"))
        let send = try #require(runner.calls.last)
        #expect(send.count == 5 && Array(send.prefix(3)) == ["file", "cp", "--update-interval=0"] && send[4] == "mac-mini:")
        #expect(send[3].hasSuffix("OpenHuman-feedback-\(FeedbackBundler.stamp(FeedbackBundlerTests.now)).zip"))
        let bytes = try #require(runner.sentBytes, "the file existed while the CLI ran")
        let entries = try #require(ZipArchive.read(bytes))
        #expect(entries.keys.contains { $0.hasSuffix("/note.txt") } && entries.keys.contains { $0.hasSuffix("/diagnostics/log.txt") })
        let log = String(decoding: try #require(entries.first { $0.key.hasSuffix("log.txt") }?.value), as: UTF8.self)
        #expect(!log.contains("leak@example.com"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "temporary folder deleted after the send")
    }

    @Test func defaultsAreDiagnosticsOnScreenshotAndThreadOff() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        let model = try make(runner, screenshot: Data([9]), thread: FeedbackThreadHeader(subject: "Private subject", senderName: "Sam"))
        #expect(model.includeDiagnostics && !model.includeScreenshot && !model.includeThread)
        await model.load()
        model.selectedDevice = "mac-mini"
        await model.send()
        let sent = try #require(runner.sentBytes)
        let entries = try #require(ZipArchive.read(sent))
        #expect(!entries.keys.contains { $0.hasSuffix("screenshot.png") || $0.hasSuffix("thread.txt") })
        let all = entries.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!all.contains("Private subject"))
    }

    @Test func tickedBoxesAddTheirParts() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        let model = try make(runner, screenshot: Data([9]), thread: FeedbackThreadHeader(subject: "Subj", senderName: "Sam"),
                             contributors: [FakeContributor()])
        await model.load()
        model.selectedDevice = "mac-mini"
        model.includeScreenshot = true
        model.includeThread = true
        model.includeDiagnostics = false
        model.extraSelection["conversationDebug"] = true
        await model.send()
        let sent = try #require(runner.sentBytes)
        let entries = try #require(ZipArchive.read(sent))
        #expect(entries.keys.contains { $0.hasSuffix("screenshot.png") })
        #expect(entries.keys.contains { $0.hasSuffix("thread.txt") })
        #expect(entries.keys.contains { $0.hasSuffix("extra/conversationDebug/debug.txt") })
        #expect(!entries.keys.contains { $0.contains("diagnostics/") })
    }

    @Test func noCLIOffersOnlySaveAndShare() async throws {
        defer { cleanUp() }
        let recorder = Recorder()
        let model = try make(nil, recorder: recorder)
        #expect(model.deviceState == .noCLI)
        await model.load()
        #expect(model.deviceState == .noCLI && model.showsFallbacks && !model.canSend)
        await model.send()
        #expect(model.phase == .editing, "send does nothing without the CLI")
        await model.saveInstead()
        guard case .saved(let name) = model.phase else { Issue.record("expected saved"); return }
        #expect(name.hasPrefix("OpenHuman-feedback-"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        await model.share()
        #expect(recorder.shared.count == 1)
        #expect(FileManager.default.fileExists(atPath: recorder.shared[0].path))
        model.removeSharedCopyNow()
        #expect(!FileManager.default.fileExists(atPath: recorder.shared[0].path))
    }

    private func entries(at url: URL) throws -> [String: Data] {
        try #require(ZipArchive.read(try Data(contentsOf: url)))
    }

    private func note(in entries: [String: Data]) throws -> String {
        String(decoding: try #require(entries.first { $0.key.hasSuffix("/note.txt") }?.value), as: UTF8.self)
    }

    private func hasScreenshot(_ entries: [String: Data]) -> Bool {
        entries.keys.contains { $0.hasSuffix("screenshot.png") }
    }

    @Test func everyShareIsBuiltFromTheCurrentSelectionsAndNote() async throws {
        defer { cleanUp() }
        let recorder = Recorder()
        let model = try make(nil, recorder: recorder, screenshot: Data([9]))
        model.includeScreenshot = true
        model.note = "first words"
        await model.share()
        model.includeScreenshot = false
        model.note = "second words"
        await model.share()

        #expect(recorder.shared.count == 2)
        let first = try entries(at: recorder.shared[0])
        #expect(hasScreenshot(first))
        #expect(try note(in: first).contains("first words"))
        #expect(recorder.shared[1] != recorder.shared[0], "a new file, never the earlier one")
        let second = try entries(at: recorder.shared[1])
        let secondNote = try note(in: second)
        #expect(!hasScreenshot(second), "unticked after the first share")
        #expect(secondNote.contains("second words") && !secondNote.contains("first words"))
        model.removeSharedCopyNow()
        #expect(recorder.shared.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func aShareAfterAFailedSendIsBuiltFromTheCurrentSelectionsAndNote() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        runner.sendResult = .success(TailscaleRunResult(exitCode: 1, errorText: "no such host"))
        let recorder = Recorder()
        let model = try make(runner, recorder: recorder, screenshot: Data([9]))
        await model.load()
        model.selectedDevice = "mac-mini"
        model.includeScreenshot = true
        model.note = "words for the send"
        await model.send()
        guard case .failed = model.phase else { Issue.record("expected failure"); return }
        let sent = try #require(runner.sentBytes)
        #expect(hasScreenshot(try #require(ZipArchive.read(sent))))

        model.includeScreenshot = false
        model.note = "words for the share"
        await model.share()
        let shared = try entries(at: try #require(recorder.shared.first))
        #expect(!hasScreenshot(shared))
        #expect(try note(in: shared).contains("words for the share"))
        model.removeSharedCopyNow()
    }

    @Test func aFailedSendShowsAPlainMessageAndKeepsTheFallbacks() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        runner.sendResult = .success(TailscaleRunResult(exitCode: 1, errorText: "send to mac-mini: no such host person@example.com"))
        let model = try make(runner)
        await model.load()
        model.selectedDevice = "mac-mini"
        await model.send()
        guard case .failed(let message) = model.phase else { Issue.record("expected failure"); return }
        #expect(!message.contains("example.com") && !message.contains("no such host"), "the CLI's text is never shown")
        #expect(message.contains("Mac mini"))
        #expect(model.showsFallbacks && model.canSend)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "deleted after a failed send too")
        await model.saveInstead()
        #expect({ if case .saved = model.phase { true } else { false } }())
    }

    @Test func aTimeoutIsPlain() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        runner.sendResult = .failure(.timedOut)
        let model = try make(runner)
        await model.load()
        model.selectedDevice = "mac-mini"
        await model.send()
        guard case .failed(let message) = model.phase else { Issue.record("expected failure"); return }
        #expect(message.contains("too long"))
    }

    @Test func unavailableStates() async throws {
        defer { cleanUp() }
        let stopped = FakeTailscale()
        stopped.statusResult = .success(TailscaleRunResult(exitCode: 0, output: TailscaleFixtures.status(backend: "Stopped")))
        let a = try make(stopped)
        await a.load()
        guard case .unavailable(let why) = a.deviceState else { Issue.record("expected unavailable"); return }
        #expect(why.contains("not running") && a.showsFallbacks)

        let slow = FakeTailscale()
        slow.statusResult = .failure(.timedOut)
        let b = try make(slow)
        await b.load()
        #expect({ if case .unavailable = b.deviceState { true } else { false } }())

        let empty = FakeTailscale()
        empty.statusResult = .success(TailscaleRunResult(exitCode: 0, output: Data(#"{"BackendState":"Running","Self":{"UserID":1},"Peer":{}}"#.utf8)))
        let c = try make(empty)
        await c.load()
        #expect({ if case .unavailable = c.deviceState { true } else { false } }())
    }

    @Test func aDeviceMissingFromTheListIsNeverSentTo() async throws {
        defer { cleanUp() }
        let runner = FakeTailscale()
        let model = try make(runner)
        await model.load()
        model.selectedDevice = "not-on-the-list"
        #expect(!model.canSend)
        await model.send()
        #expect(runner.calls == [TaildropArguments.statusArguments])
    }
}

@MainActor
struct SendFeedbackCenterTests {
    @Test func beginNeedsTheAppsFactoryAndOpensOnce() async {
        let center = SendFeedbackCenter()
        center.isOffered = { true }
        #expect(!center.canBegin)
        center.begin()
        #expect(center.model == nil)
        var made = 0
        var shown = 0
        center.showWindow = { shown += 1 }
        center.makeModel = {
            made += 1
            return SendFeedbackModel(SendFeedbackDependencies(runner: nil, appInfo: { FeedbackBundlerTests.app }))
        }
        center.begin()
        center.begin()
        #expect(made == 1 && shown == 1 && center.isPresented)
        center.isPresented = false
        #expect(center.model == nil)
    }
}
