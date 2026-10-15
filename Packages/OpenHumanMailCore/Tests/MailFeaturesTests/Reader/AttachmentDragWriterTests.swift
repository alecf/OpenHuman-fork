import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

struct AttachmentDragWriterTests {
    static let key = MessageKey(account: AccountID(1), rowID: 7, gmailMessageID: GmailMessageID("m7"))
    static let pdf = AttachmentInfo(id: 3, filename: "Q3 \u{202E}fdp.exe/../invoice.pdf", mimeType: "application/pdf", size: 12,
                                    contentID: nil, isInline: false)

    final class Source: Sendable {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID().uuidString)")
        let file: URL
        let calls = Mutex(0)
        let gate: TestGate?
        let failure: (any Error & Sendable)?

        init(gate: TestGate? = nil, failure: (any Error & Sendable)? = nil) throws {
            file = folder.appendingPathComponent("source.bin")
            self.gate = gate
            self.failure = failure
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic attachment bytes".utf8).write(to: file)
            try AttachmentFiles.setQuarantine("0083;00000000;OpenHuman Fetcher;TEST", on: file)
        }

        var writer: AttachmentDragWriter {
            AttachmentDragWriter(fetch: { [self] _, _ in
                calls.withLock { $0 += 1 }
                if let gate { await gate.wait() }
                if let failure { throw failure }
                return file
            })
        }

        func destination() throws -> URL {
            let url = folder.appendingPathComponent("Desktop-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func contents(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    @Test func aFolderGetsTheSafeNameTheBytesAndTheSourcesQuarantine() async throws {
        let source = try Source()
        let desktop = try source.destination()
        let written = try await source.writer.write(Self.pdf, of: Self.key, to: desktop)
        #expect(written.lastPathComponent == ReaderFormatting.safeFilename(Self.pdf.filename))
        #expect(written.deletingLastPathComponent().standardizedFileURL == desktop.standardizedFileURL)
        #expect(try Data(contentsOf: written) == Data(contentsOf: source.file))
        #expect(AttachmentFiles.quarantine(of: written) == AttachmentFiles.quarantine(of: source.file))
        #expect(source.contents(desktop) == [written.lastPathComponent], "no temporary file is left")
        #expect(AttachmentDragWriter.fileName(for: Self.pdf) == ReaderFormatting.safeFilename(Self.pdf.filename))
    }

    @Test func aNewFileURLIsUsedAndAnExistingOneIsNeverReplaced() async throws {
        let source = try Source()
        let desktop = try source.destination()
        let target = desktop.appendingPathComponent("invoice.pdf")
        let first = try await source.writer.write(Self.pdf, of: Self.key, to: target)
        #expect(first.lastPathComponent == "invoice.pdf")
        try Data("the user's own file".utf8).write(to: target)
        let second = try await source.writer.write(Self.pdf, of: Self.key, to: target)
        #expect(second.lastPathComponent == "invoice 2.pdf")
        #expect(try Data(contentsOf: target) == Data("the user's own file".utf8), "the existing file is untouched")
        let safe = ReaderFormatting.safeFilename(Self.pdf.filename)
        let once = try await source.writer.write(Self.pdf, of: Self.key, to: desktop)
        let twice = try await source.writer.write(Self.pdf, of: Self.key, to: desktop)
        #expect(once.lastPathComponent == safe)
        #expect(twice.lastPathComponent == (safe as NSString).deletingPathExtension + " 2.pdf")
        #expect(source.contents(desktop).allSatisfy { !$0.hasSuffix(".openhuman-partial") })
    }

    @Test func aFailedFetchLeavesNoFile() async throws {
        let source = try Source(failure: MailPortError.notFound("attachment"))
        let desktop = try source.destination()
        await #expect(throws: (any Error).self) { try await source.writer.write(Self.pdf, of: Self.key, to: desktop) }
        #expect(source.contents(desktop).isEmpty)
    }

    @Test func aCancelledDropLeavesNoFile() async throws {
        let gate = TestGate()
        let source = try Source(gate: gate)
        let desktop = try source.destination()
        let writer = source.writer
        let task = Task { try await writer.write(Self.pdf, of: Self.key, to: desktop) }
        await eventuallyCalled(source)
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.contents(desktop).isEmpty)
    }

    @Test func manyDropsAndAReadOfOneAttachmentFetchItOnce() async throws {
        let gate = TestGate()
        let source = try Source(gate: gate)
        let desktop = try source.destination()
        let writer = source.writer
        writer.prepare(Self.pdf, of: Self.key)
        async let one = writer.write(Self.pdf, of: Self.key, to: desktop)
        async let two = writer.write(Self.pdf, of: Self.key, to: desktop)
        async let read = writer.file(Self.pdf, of: Self.key)
        await eventuallyCalled(source)
        gate.release()
        let written = try await [one, two]
        _ = try await read
        #expect(Set(written.map(\.lastPathComponent)).count == 2)
        #expect(source.contents(desktop).count == 2, "neither drop replaced the other")
        #expect(source.calls.withLock { $0 } == 1, "one attachmentData call")
    }

    @Test func concurrentDropsIntoOneFolderNeverReplaceEachOther() async throws {
        let source = try Source()
        let writer = source.writer
        let drops = 8
        for _ in 0..<25 {
            let desktop = try source.destination()
            let written = try await withThrowingTaskGroup(of: URL.self) { group in
                for _ in 0..<drops { group.addTask { try await writer.write(Self.pdf, of: Self.key, to: desktop) } }
                return try await group.reduce(into: [URL]()) { $0.append($1) }
            }
            #expect(Set(written.map(\.lastPathComponent)).count == drops)
            #expect(source.contents(desktop).count == drops, "every drop left its own file")
            #expect(source.contents(desktop).allSatisfy { !$0.hasSuffix(".openhuman-partial") })
        }
    }

    @Test func anExclusiveMoveNeverReplacesAnExistingFile() throws {
        let source = try Source()
        let desktop = try source.destination()
        let target = desktop.appendingPathComponent("taken.pdf")
        try Data("the user's own file".utf8).write(to: target)
        let moving = desktop.appendingPathComponent("moving.bin")
        try Data("dropped".utf8).write(to: moving)
        #expect(try AttachmentDragWriter.moveExclusively(moving, to: target) == false)
        #expect(try Data(contentsOf: target) == Data("the user's own file".utf8))
        let free = desktop.appendingPathComponent("free.pdf")
        #expect(try AttachmentDragWriter.moveExclusively(moving, to: free))
        #expect(try Data(contentsOf: free) == Data("dropped".utf8))
        #expect(!FileManager.default.fileExists(atPath: moving.path))
    }

    @Test func theSavePanelStillReplacesAndANonReplacingSaveDoesNot() throws {
        let source = try Source()
        let desktop = try source.destination()
        let target = desktop.appendingPathComponent("report.pdf")
        try Data("old".utf8).write(to: target)
        let kept = try AttachmentFiles.save(source.file, filename: "report.pdf", to: target, replacing: false)
        #expect(kept.lastPathComponent == "report 2.pdf")
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        let replaced = try AttachmentFiles.save(source.file, filename: "report.pdf", to: target)
        #expect(replaced == target)
        #expect(try Data(contentsOf: target) == Data(contentsOf: source.file), "the default keeps the save panel's replace")
    }

    @MainActor
    @Test func theModuleInstallsTheWriterAndOffLeavesNone() {
        let on = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), featureFlags: FeatureFlags())
        #expect(on.attachmentDrag != nil && on.modules.modules.contains(.attachmentDragOut))
        let off = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow),
                                      featureFlags: FeatureFlags().with(.attachmentDragOut, false))
        #expect(off.attachmentDrag == nil)
        #expect(FeaturesSettingsModel.info(.attachmentDragOut).title == "Drag attachments out")
    }

    @MainActor
    @Test func dragsOverTheFakeStoreWriteSyntheticBytesAndChangeNoMail() async throws {
        let store = FakeMailStore(corpus: .rich(threadCount: 40, now: fixedNow))
        let recorder = RecordingCommands(store)
        let env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: true,
                                 featureFlags: FeatureFlags())
        let account = try #require(FakeCorpus.rich(threadCount: 40, now: fixedNow).accounts.first?.id)
        let rows = try await store.threadPage(.system(.allMail), account: account, after: nil, limit: 1_000).rows
        var found: (MessageKey, AttachmentInfo)?
        for row in rows where found == nil {
            guard let detail = try await first(store.threadDetail(row.id)) ?? nil else { continue }
            for message in detail.messages {
                if let attachment = message.attachments.first(where: { !$0.isInline }) { found = (message.id, attachment); break }
            }
        }
        let (key, attachment) = try #require(found)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drag-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try await #require(env.attachmentDrag).write(attachment, of: key, to: folder)
        #expect(AttachmentFiles.quarantine(of: written) != nil)
        #expect(recorder.calls.isEmpty, "a drag changes no mail")
    }

    private func eventuallyCalled(_ source: Source) async {
        let clock = ContinuousClock()
        let deadline = clock.now + testBackstop
        while source.calls.withLock({ $0 }) == 0, clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
