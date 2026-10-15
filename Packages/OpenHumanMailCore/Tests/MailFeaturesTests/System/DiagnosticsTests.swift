import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

struct ZipArchiveTests {
    @Test func crcOfTheStandardCheckString() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func roundTripsEntriesAndNames() throws {
        var zip = ZipArchive()
        zip.add(name: "a.txt", text: "hello", modified: Date(timeIntervalSince1970: 1_791_000_000))
        zip.add(name: "dir/b.json", data: Data([0, 1, 2, 255]))
        let entries = try #require(ZipArchive.read(zip.data()))
        #expect(entries["a.txt"] == Data("hello".utf8))
        #expect(entries["dir/b.json"] == Data([0, 1, 2, 255]))
        #expect(zip.count == 2)
    }

    @Test func endsWithAValidDirectoryRecord() {
        var zip = ZipArchive()
        zip.add(name: "x", text: "y")
        let bytes = [UInt8](zip.data())
        let eocd = bytes.count - 22
        #expect(Array(bytes[eocd..<(eocd + 4)]) == [0x50, 0x4B, 0x05, 0x06])
        #expect(bytes[eocd + 10] == 1, "one entry")
    }
}

@MainActor
@Suite(.serialized)
struct DiagnosticsExportTests {
    static let markers = ["MARKERSUBJECT", "MARKERBODYTEXT", "marker.person@markerdomain.example", "MARKERLABELNAME",
                          "MARKERSENDERNAME", "MARKERATTACHMENT"]

    private func exporter(_ f: SystemFixture, logs: [String] = []) -> DiagnosticsExporter {
        DiagnosticsExporter(data: f.store,
                            info: { DiagnosticsAppInfo(version: "1.0", build: "7", gitCommit: "abc1234", os: "macOS 27", dataMode: "fake") },
                            modules: { ["notifications": true, "unsubscribe": false] }, logLines: { logs }, now: { fixedNow })
    }

    @Test func theZipFromASeededFakeStoreContainsNoneOfTheMarkers() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 5, now: fixedNow))
        let sender = EmailAddress(name: "MARKERSENDERNAME", email: "marker.person@markerdomain.example")
        f.store.deliverMessage(account: f.account, from: sender, subject: "MARKERSUBJECT", text: "MARKERBODYTEXT", important: true)
        let row = try await f.firstThread()
        _ = try await f.store.createLabel(f.account, name: "MARKERLABELNAME", applyTo: [row.id])
        let logs = ["sync account 1 finished", "thread from marker.person@markerdomain.example failed",
                    "consent at https://accounts.example/o?code=4/0AbCdEfGhIjKlMnOpQrStUv"]
        let bytes = try await exporter(f, logs: logs).build()
        let text = String(decoding: bytes, as: UTF8.self)
        for marker in Self.markers { #expect(!text.contains(marker), "\(marker) leaked into the export") }
        let entries = try #require(ZipArchive.read(bytes))
        #expect(Set(entries.keys) == ["README.txt", "diagnostics.json", "log.txt"])
        for (name, data) in entries {
            let body = String(decoding: data, as: UTF8.self)
            for marker in Self.markers { #expect(!body.contains(marker), "\(marker) in \(name)") }
            #expect(!body.contains("@"), "no address-like text in \(name)")
        }
        let log = String(decoding: try #require(entries["log.txt"]), as: UTF8.self)
        #expect(log.contains("sync account 1 finished") && !log.contains("0AbCdEf"))
    }

    @Test func theLogComesFromTheBufferRedactedWithoutAddressesOrQuotedText() async throws {
        let f = SystemFixture(corpus: .small)
        let buffer = DevFeedbackLogBuffer()
        buffer.append(.init(at: fixedNow, category: "sync", level: "info", message: "account 1 synced, 3 changed"))
        buffer.append(.init(at: fixedNow, category: "sync", level: "error", message: "failed for marker.person@markerdomain.example subject \"MARKERSUBJECT\""))
        let exporter = DiagnosticsExporter(data: f.store,
                                           info: { DiagnosticsAppInfo(version: "1", build: "1", gitCommit: "x", os: "macOS", dataMode: "fake") },
                                           modules: { [:] }, logLines: { buffer.diagnosticLines(now: fixedNow) }, now: { fixedNow })
        let entries = try #require(ZipArchive.read(try await exporter.build()))
        let log = String(decoding: try #require(entries["log.txt"]), as: UTF8.self)
        #expect(log.contains("info sync account 1 synced, 3 changed") && log.contains("error sync failed for <email>"))
        #expect(!log.contains("MARKER") && !log.contains("@") && !log.contains("no log lines"))
    }

    @Test func theDocumentHasVersionsFlagsAndNumberedAccounts() async throws {
        let f = SystemFixture(corpus: .small, options: .init(remoteAck: .immediate))
        let bytes = try await exporter(f).build()
        let entries = try #require(ZipArchive.read(bytes))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(DiagnosticsDocument.self, from: try #require(entries["diagnostics.json"]))
        #expect(document.app.gitCommit == "abc1234" && document.app.version == "1.0")
        #expect(document.modules == ["notifications": true, "unsubscribe": false])
        #expect(document.snapshot.accounts.map(\.index) == [1, 2])
    }

    @Test func aMisbehavingSourceCannotSmuggleContentThroughTheSnapshot() async throws {
        let hostile = DiagnosticsSnapshot(
            generatedAt: fixedNow,
            accounts: [.init(index: 1, health: "ok", connectivity: "syncFailing(ada@leaky.example)", threadCount: 1, messageCount: 1,
                             draftCount: 0, pendingOperations: 0, failedOperations: 0)],
            operations: [.init(kind: "Subject: private thing", status: "pending", count: 2)],
            recentErrors: [.init(code: "server_503", count: 1)])
        let clean = DiagnosticsExporter.sanitized(hostile)
        #expect(clean.accounts[0].connectivity == "<redacted>")
        #expect(clean.operations[0].kind == "<redacted>")
        #expect(clean.recentErrors[0].code == "server_503")
        #expect(clean.accounts[0].health == "ok")
    }

    @Test func exportWritesTheFileAndModuleOffRemovesTheMenu() async throws {
        let f = SystemFixture(corpus: .make(threadCount: 3, now: fixedNow))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oh-diag-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try await exporter(f).export(to: url)
        #expect(ZipArchive.read(try Data(contentsOf: url))?["diagnostics.json"] != nil)
        #expect(exporter(f).suggestedFileName() == "Mail-Diagnostics-20261001-095000.zip" || exporter(f).suggestedFileName().hasPrefix("Mail-Diagnostics-"))

        let off = SystemFixture(flags: FeatureFlags().with(.diagnostics, false))
        off.env.runLaunchTasks()
        #expect(off.env.system.diagnostics == nil)
        await off.env.system.exportDiagnostics()
        #expect(off.env.notices.toasts.isEmpty)
    }
}
