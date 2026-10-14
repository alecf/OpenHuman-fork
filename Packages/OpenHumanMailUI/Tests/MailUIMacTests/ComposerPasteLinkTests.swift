import AppKit
import MailRender
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ComposerPasteLinkTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let bridge = AttributedBridge(font: .systemFont(ofSize: 14))

    init() { window.isReleasedWhenClosed = false }

    func editor() -> ComposerTextView {
        let text = ComposerTextView.make()
        text.bridge = bridge
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(text)
        return text
    }

    func clipboard(for text: ComposerTextView, string: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString(string, forType: .string)
        text.pasteboard = { board }
        return board
    }

    @Test func aLinkPastedOverSelectedTextLinksIt() throws {
        let text = editor()
        let board = clipboard(for: text, string: "  https://example.com/plan?utm_source=news&id=7\n")
        defer { board.releaseGlobally() }
        text.insertText("the plan here", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 4, length: 4))
        text.toggle(.bold)
        text.paste(nil)
        let url = try #require(URL(string: "https://example.com/plan?id=7"))
        #expect(text.document == RichTextDocument(blocks: [
            .paragraph([.text("the ", []), .link(url, [.text("plan", .bold)]), .text(" here", [])]),
        ]), "\(text.document)")
        #expect(text.string == "the plan here", "the words stay")
    }

    @Test func aMailLinkWorksAndNothingSelectedPastesTheText() {
        let text = editor()
        let board = clipboard(for: text, string: "mailto:someone@example.org")
        defer { board.releaseGlobally() }
        text.insertText("write ", replacementRange: NSRange(location: 0, length: 0))
        text.paste(nil)
        #expect(text.string == "write mailto:someone@example.org", "no selection: an ordinary paste")
        text.setSelectedRange(NSRange(location: 0, length: 5))
        text.paste(nil)
        if case .paragraph(let inlines)? = text.document.blocks.first, case .link(let url, _)? = inlines.first {
            #expect(url.absoluteString == "mailto:someone@example.org")
        } else {
            Issue.record("not linked: \(text.document)")
        }
    }

    @Test func moreThanALinkReplacesTheSelectionAsBefore() {
        let text = editor()
        let board = clipboard(for: text, string: "see https://example.com")
        defer { board.releaseGlobally() }
        text.insertText("old words", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 3))
        text.paste(nil)
        #expect(text.string == "see https://example.com words")
    }
}
