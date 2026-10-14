import Foundation
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct PlainTextModeTests {
    @Test func plainTextModeSavesNoHTMLAndTheLogicalLines() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.updateBody(RichTextDocument(blocks: [
            .paragraph([.text("Bold start ", [.bold]), .text("and a long line that the data layer wraps only when it sends.", [])]),
            .paragraph([]),
            .paragraph([.text("Second paragraph.", [])]),
        ]))
        #expect(!session.isPlainText)
        session.setPlainText(true)
        #expect(session.isPlainText)
        let fields = session.assembledFields()
        #expect(fields.bodyHTML.isEmpty, "no HTML part: the draft's plain-text mark")
        let text = try #require(fields.bodyText)
        #expect(text.hasPrefix("Bold start and a long line that the data layer wraps only when it sends.\n\nSecond paragraph."))
        #expect(!text.contains("\n and"), "never wrapped here: the logical lines go to the data layer")
        #expect(session.document.blocks.allSatisfy { block in
            if case .paragraph(let runs) = block { return runs.allSatisfy { if case .text(_, let marks) = $0 { marks.isEmpty } else { true } } }
            return true
        })
        session.setPlainText(false)
        #expect(!session.assembledFields().bodyHTML.isEmpty)
    }

    @Test func aDraftStoredAsPlainTextReopensInPlainTextMode() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let stored = "Hello Dana,\n\nSee you Tuesday.\n\n-- \nSam"
        let row = DraftSummary(id: DraftKey("00000000-0000-4000-8000-0000000000aa"), account: ComposeFixture.work, mode: .new,
                               fields: DraftFields(to: [EmailAddress(email: "dana@example.com")], subject: "Tuesday",
                                                   bodyHTML: "", bodyText: stored),
                               updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        session.load(from: row, recovered: nil)
        #expect(session.isPlainText)
        #expect(!session.includesSignature, "the stored text already carries what was saved")
        #expect(session.assembledFields().bodyText == stored.replacingOccurrences(of: "\n-- \n", with: "\n--\n"))
        #expect(session.assembledFields().bodyHTML.isEmpty)
    }

    @Test func formattingDoesNothingInPlainText() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.setPlainText(true)
        session.applyFormat(.bold)
        #expect(session.isPlainText)
    }
}
