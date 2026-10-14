import Foundation
import MailModel
import OpenHumanCore
import OpenHumanSemanticIndex
import OpenHumanStore
import Testing
@testable import OpenHumanMail

@Suite("Smart search wiring")
struct SemanticWiringTests {
    private func query(_ text: String, _ terms: [SearchTerm]) -> SearchQuery { SearchQuery(text: text, terms: terms) }

    @Test func theArmRunsOnlyForFreeText() {
        #expect(SemanticSearchArm.plan(query("moving our retreat", [.text("moving", field: nil), .text("our", field: nil),
                                                                    .text("retreat", field: nil)]))?.text == "moving our retreat")
        #expect(SemanticSearchArm.plan(query("from:dana", [.address(.from, "dana")])) == nil)
        #expect(SemanticSearchArm.plan(query("PO", [.text("PO", field: nil)])) == nil)
        #expect(SemanticSearchArm.plan(query("\"invoice 4471\"", [.text("invoice 4471", field: nil)])) == nil)
        #expect(SemanticSearchArm.plan(query("rfc822msgid:abc offsite", [.rfc822msgid("abc"), .text("offsite", field: nil)])) == nil)
        let filtered = SemanticSearchArm.plan(query("offsite from:dana after:2026/01/01",
                                                    [.text("offsite", field: nil), .address(.from, "dana"),
                                                     .after(Date(timeIntervalSince1970: 1_767_225_600))]))
        #expect(filtered?.structured == true)
        #expect(filtered?.after == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(SemanticSearchArm.plan(query("offsite after:2026/01/01", [.text("offsite", field: nil),
                                                                          .after(Date(timeIntervalSince1970: 0))]))?.structured == false)
    }

    @Test func storeRowsMapToCorpusMessages() {
        let message = IndexableMessage(message: MessageRowID(rawValue: 7), account: AccountID(2), gmailMessageID: GmailMessageID("g7"),
                                       thread: ThreadRowID(rawValue: 70), internalDate: Date(timeIntervalSince1970: 100),
                                       bodyState: .failed, isDraft: false, inSpam: true)
        let corpus = StoreSemanticSource.corpus(message)
        #expect(corpus.mid == 7 && corpus.account == 2 && corpus.gmailID == "g7" && corpus.thread == 70)
        #expect(corpus.bodyState == 3 && !corpus.isEligible)
    }

    @Test func statusLinesFollowTheSpecWording() {
        var progress = SemanticIndexProgress(phase: .indexing, embedded: 18_004, eligible: 42_870)
        #expect(SmartSearchIndexSettingsView.status(progress).hasPrefix("Indexing · 41%"))
        progress.phase = .paused(.lowPower)
        #expect(SmartSearchIndexSettingsView.status(progress) == "Paused: Low Power Mode is on")
        progress.phase = .off(.aiOff)
        #expect(SmartSearchIndexSettingsView.status(progress) == "Off: AI is turned off in Settings › AI")
        #expect(SmartSearchIndexSettingsView.size(0) == "Not built")
    }

    @Test func deletingTheIndexTurnsItOffAndRemovesTheFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ohsemantic-app-\(UUID().uuidString)")
            .appendingPathComponent(SemanticIndex.folderName)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let index = try SemanticIndex(location: .directory(folder))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        try await index.destroy()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await !index.isUsable)
    }

    @Test func progressMapsToWhatTheListShows() {
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .off(.disabled))) == SmartSearchStatus.off)
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .failed("open"))) == SmartSearchStatus.off)
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .ready, embedded: 10, eligible: 10)) == SmartSearchStatus.ready)
        let indexing = SemanticServices.status(SemanticIndexProgress(phase: .indexing, embedded: 18_004, eligible: 42_870))
        #expect(indexing == SmartSearchStatus(phase: .indexing, fraction: 0.41))
        let searching = SemanticServices.status(SemanticIndexProgress(phase: .paused(.userActive), embedded: 5, eligible: 10))
        #expect(searching.phase == .indexing)
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .paused(.userActive), embedded: 10, eligible: 10))
                == SmartSearchStatus.ready)
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .paused(.lowPower), embedded: 5, eligible: 10)).phase
                == .paused(.lowPower))
        #expect(SemanticServices.status(SemanticIndexProgress(phase: .rebuilding(fraction: 0.257))).fraction == 0.25)
    }
}
