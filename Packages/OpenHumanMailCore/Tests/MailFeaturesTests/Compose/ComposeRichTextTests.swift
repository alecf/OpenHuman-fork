import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class RecordingFormatter: ComposeFormatEditing {
    var commands: [ComposeFormatCommand] = []
    func applyFormat(_ command: ComposeFormatCommand) { commands.append(command) }
}

@MainActor
@Suite(.serialized) struct ComposeRichTextTests {
    func picture(named name: String) throws -> (file: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)
        return (file, folder)
    }

    @Test func anInlineImageGoesOutWithItsPartOnlyWhileTheTextShowsIt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let source = try picture(named: "Chart.png")
        defer { try? FileManager.default.removeItem(at: source.folder) }

        let ref = try #require(session.addInlineImage(file: source.file))
        #expect(ref.alt == "Chart" && ref.contentID.hasSuffix("@openhuman"))
        let part = try #require(session.attachments.first)
        #expect(part.isInline && part.contentID == ref.contentID && part.mimeType == "image/png" && part.size == 8)
        #expect(part.localPath?.hasPrefix("Drafts/") == true, "copied under the drafts directory like a file")
        #expect(session.fileAttachments.isEmpty, "an inline image is no attachment chip")
        #expect(session.hasInlineImage(ref.contentID) && !session.hasInlineImage("other@openhuman"))
        let copy = try #require(session.inlineImageFile(ref.contentID))
        #expect(FileManager.default.fileExists(atPath: copy.path) && copy != source.file)

        session.to.text = "Dana Ruiz <dana@acme.example>,"
        session.updateBody(RichTextDocument(blocks: [.paragraph([.text("See the chart", [])]), .image(ref)]))
        let fields = session.assembledFields()
        #expect(fields.bodyHTML.contains("<img src=\"cid:\(ref.contentID)\" alt=\"Chart\""))
        #expect(fields.bodyText?.contains("See the chart\n[image: Chart]") == true, "the text alternative names it")
        #expect(fields.attachments.map(\.contentID) == [ref.contentID] && session.attachmentBytes == 8)
        await soon { session.draftKey != nil && session.saveState == .saved }
        let key = try #require(session.draftKey)
        let row = try #require(await f.draftRow(key))
        #expect(row.fields.attachments.first?.isInline == true && row.fields.bodyHTML.contains("cid:\(ref.contentID)"))

        session.updateBody(doc("See the chart"))
        #expect(session.assembledFields().attachments.isEmpty && session.attachmentBytes == 0)
        #expect(session.attachments.count == 1)
        session.updateBody(RichTextDocument(blocks: [.paragraph([.text("See the chart", [])]), .image(ref)]))
        #expect(session.assembledFields().attachments.count == 1)
    }

    @Test func aPictureWithoutItsPartStaysOutOfTheSentHTML() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.updateBody(RichTextDocument(blocks: [.paragraph([.text("Hi", [])]),
                                                     .image(InlineImageRef(contentID: "gone@elsewhere", alt: "Logo"))]))
        let fields = session.assembledFields()
        #expect(!fields.bodyHTML.contains("cid:") && !(fields.bodyText ?? "").contains("[image"))
        #expect(fields.bodyHTML.contains("Hi"))
    }

    @Test func pastedImageDataBecomesAnInlineImage() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let ref = try #require(session.addInlineImage(data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png"))
        #expect(ref.alt == "Pasted image")
        let copy = try #require(session.inlineImageFile(ref.contentID))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(!copy.path.contains("OpenHumanMailPaste-"), "the copy lives with the draft, not in the pasted bytes' folder")
        #expect(session.attachments.first?.mimeType == "image/png" && session.attachments.first?.size == 4)
    }

    @Test func aFileThatCannotBeCopiedSaysSo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("oh-missing-\(UUID().uuidString).png")
        #expect(session.addInlineImage(file: missing) == nil)
        #expect(session.notice == ComposeSession.Notice(.error, "Couldn't add the image.") && session.attachments.isEmpty)
    }

    @Test func thePaletteTogglesTheFormattingBarRemembersItAndTheButtonsReachTheEditor() async throws {
        let f = ComposeFixture()
        await f.loaded()
        await f.compose.settle()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(!f.compose.showsFormatBar)
        let descriptor = try #require(ActionCatalog.descriptor(.toggleFormatBar))
        #expect(descriptor.defaultBindings.map(\.description) == ["⌥⌘F"] && descriptor.shortcutHint == "⌥⌘F")
        #expect(descriptor.appearsInPalette && descriptor.scopes == [.composer] && !descriptor.changesMail)
        #expect(f.env.actions.availability(.toggleFormatBar, host: session) == .enabled)
        #expect(await f.run(.toggleFormatBar, in: session))
        #expect(f.compose.showsFormatBar)
        await f.compose.settle()
        #expect(try await f.store.get(ComposeSettings.showFormatBar) == true, "remembered")
        #expect(await f.run(.toggleFormatBar, in: session))
        await f.compose.settle()
        #expect(!f.compose.showsFormatBar)
        #expect(try await f.store.get(ComposeSettings.showFormatBar) == false)

        let editor = RecordingFormatter()
        session.formatter = editor
        session.applyFormat(.bold)
        session.applyFormat(.numberedList)
        #expect(editor.commands == [.bold, .numberedList])
        session.updateFormatState(ComposeFormatState(marks: [.bold, .italic], list: .numbered, hasSelection: true))
        #expect(session.formatState.isActive(.bold) && session.formatState.isActive(.italic))
        #expect(session.formatState.isActive(.numberedList) && !session.formatState.isActive(.bulletList))
        #expect(!session.formatState.isActive(.underline) && !session.formatState.isActive(.clearFormatting))
        #expect(f.recorder.calls.isEmpty, "formatting saves nothing by itself")
    }

    @Test func theFormattingBarIsALocalSettingThatWritesNoMail() async throws {
        let f = ComposeFixture()
        await f.loaded()
        await f.compose.settle()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(f.env.actions.availability(.toggleFormatBar, host: session) == .enabled)
        #expect(await f.run(.toggleFormatBar, in: session))
        #expect(f.compose.showsFormatBar)
        #expect(f.recorder.calls.isEmpty, "a local setting: nothing reaches the mail ports")
    }

    @Test func aPasteThatLeftAnImageOutSaysSoInOneLine() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.didPaste(ComposePaste.Report(removedParameters: 3, droppedHidden: 2))
        #expect(session.notice == nil, "removed tracking parameters and hidden text are not worth a word")
        session.didPaste(ComposePaste.Report(droppedImages: 1))
        #expect(session.notice?.kind == .info && session.notice?.text.contains("An image was left out") == true)
        session.didPaste(ComposePaste.Report(removedParameters: 1, droppedImages: 3))
        let text = try #require(session.notice?.text)
        #expect(text.contains("3 images") && !text.contains("link"))
    }

    @Test func aReopenedDraftKeepsTheSignatureChoiceItWasSavedWith() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        await session.settle()
        #expect(session.signature != nil, "the default From has a signature")
        session.to.text = "Dana Ruiz <dana@acme.example>,"
        session.includesSignature = false
        session.updateBody(doc("Without a signature"))
        await soon { session.draftKey != nil && session.saveState == .saved }
        let key = try #require(session.draftKey)
        #expect(!(try #require(await f.draftRow(key))).fields.bodyHTML.contains("gmail_signature"))
        f.compose.close(session)
        await f.compose.settle()

        f.compose.recovery.remove(key)
        let reopened = try #require(await f.compose.openDraft(key).value)
        #expect(!reopened.includesSignature)
        #expect(!reopened.assembledFields().bodyHTML.contains("gmail_signature"), "no signature grows back on save")
        f.compose.close(reopened)
        await f.compose.settle()

        let second = try #require(f.compose.openNew(placement: .modal))
        await second.settle()
        second.to.text = "Dana Ruiz <dana@acme.example>,"
        second.updateBody(doc("With a signature"))
        await soon { second.draftKey != nil && second.saveState == .saved }
        let secondKey = try #require(second.draftKey)
        f.compose.close(second)
        await f.compose.settle()
        f.compose.recovery.remove(secondKey)
        let again = try #require(await f.compose.openDraft(secondKey).value)
        #expect(again.includesSignature && again.assembledFields().bodyHTML.contains("gmail_signature"))
    }

    @Test func theQuotesTextComesFromItsHTMLWhenTheStoredTextLacksIt() {
        let quote = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div dir=\"ltr\" class=\"gmail_attr\">On Oct 1, Dana "
            + "&lt;dana@acme.example&gt; wrote:<br></div><blockquote>Hi<br>there</blockquote></div>"
        for text in [nil, "Thanks", "Something else entirely"] as [String?] {
            let split = QuoteSplit.splitText(text, quoteHTML: quote, ownText: "Thanks")
            #expect(split.hasPrefix("On Oct 1, Dana <dana@acme.example> wrote:"), "\(String(describing: text)): \(split)")
            #expect(split.contains("> Hi") && split.contains("> there"))
        }
        #expect(QuoteSplit.splitText(nil, quoteHTML: "", ownText: "Thanks") == "", "no quote, no quote text")
        let forward = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">---------- Forwarded message "
            + "---------<br>From: Dana<br></div><div>Body</div></div>"
        let forwarded = QuoteSplit.text(fromQuoteHTML: forward)
        #expect(forwarded.hasPrefix("---------- Forwarded message") && !forwarded.contains("> "))
    }
}
