import AppKit
import MailActions
import MailFeatures
import MailRender
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ComposerListLevelTests {
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

    func key(_ chars: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func item(_ text: String) -> [RichTextDocument.Block] { [.paragraph([.text(text, [])])] }

    func caret(in text: ComposerTextView, at word: String) {
        text.setSelectedRange(NSRange(location: (text.string as NSString).range(of: word).location, length: 0))
    }

    @Test func commandBracketsMoveListItemsOneLevelPerPress() {
        let text = editor()
        let flat = RichTextDocument(blocks: [.list(ordered: false, items: [item("one"), item("two"), item("three")])])
        text.load(flat)

        caret(in: text, at: "two")
        #expect(text.handleCommandKey(key("]", code: 30)))
        let twoIn = RichTextDocument(blocks: [.list(ordered: false, items: [
            item("one") + [.list(ordered: false, items: [item("two")])], item("three"),
        ])])
        #expect(text.document == twoIn, "\(text.document)")

        text.applyFormatting(.formatIndent)
        #expect(text.document == twoIn)

        caret(in: text, at: "three")
        text.applyFormatting(.formatIndent)
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: false, items: [
            item("one") + [.list(ordered: false, items: [item("two"), item("three")])],
        ])]))

        #expect(text.handleCommandKey(key("[", code: 33)))
        #expect(text.document == twoIn)
        caret(in: text, at: "two")
        text.applyFormatting(.formatOutdent)
        #expect(text.document == flat)

        caret(in: text, at: "one")
        text.applyFormatting(.formatIndent)
        text.applyFormatting(.formatOutdent)
        #expect(text.document == flat)
    }

    @Test func plainParagraphsAreLeftAloneAndNumberedListsNestNumbers() {
        let text = editor()
        let plain = RichTextDocument(blocks: [.paragraph([.text("not a list", [])])])
        text.load(plain)
        caret(in: text, at: "list")
        #expect(text.handleCommandKey(key("]", code: 30)), "the key is the composer's either way")
        #expect(text.document == plain)

        let numbered = RichTextDocument(blocks: [.list(ordered: true, items: [item("first"), item("second")])])
        text.load(numbered)
        caret(in: text, at: "second")
        text.applyFormatting(.formatIndent)
        #expect(text.document == RichTextDocument(blocks: [.list(ordered: true, items: [
            item("first") + [.list(ordered: true, items: [item("second")])],
        ])]))
        #expect(text.string.contains("\t1.\tsecond") || text.string.contains("\t1\tsecond"), "numbered from 1 at its level")
    }

    @Test func nestedListsRoundTripThroughTheBridge() {
        let nested = RichTextDocument(blocks: [.list(ordered: false, items: [
            item("a") + [.list(ordered: true, items: [item("b"), item("c") + [.list(ordered: false, items: [item("d")])]])],
            item("e"),
        ])])
        #expect(bridge.document(bridge.attributedString(nested)) == nested)
        #expect(AttributedBridge.markerFormat(ordered: false, depth: 0) == .disc)
        #expect(AttributedBridge.markerFormat(ordered: false, depth: 1) == .circle)
        #expect(AttributedBridge.markerFormat(ordered: false, depth: 2) == .square)
        #expect(AttributedBridge.markerFormat(ordered: true, depth: 3) == .decimal)
    }
}

@MainActor
@Suite struct ThreadListZoomTests {
    @Test func theRowsTypeAndHeightScaleAndOnlyThem() {
        let base = ThemeTokens.light
        #expect(base.listZoomed(1) == base)
        let big = base.listZoomed(1.5)
        #expect(big.typeBody.size == (base.typeBody.size * 1.5 * 2).rounded() / 2)
        #expect(big.typeBody.lineHeight == (base.typeBody.lineHeight * 1.5).rounded())
        #expect(big.rowHeight == (base.rowHeight * 1.5).rounded())
        #expect(big.textPrimary == base.textPrimary && big.space3 == base.space3, "colours and spacing unchanged")
        #expect(big.typeReader == base.typeReader, "the reader zooms its own way")
    }

    @Test func theListFollowsTheUIZoomWithoutAReload() async throws {
        let zoom = ReaderPreferences(defaults: nil)
        let controller = ThreadListViewController(theme: .light, zoom: zoom)
        _ = controller.view
        let base = controller.tableView.rowHeight
        #expect(base == CGFloat(ThemeTokens.light.rowHeight))
        zoom.zoomIn()
        zoom.zoomIn()
        try await until { controller.tableView.rowHeight == CGFloat((ThemeTokens.light.rowHeight * 1.25).rounded()) }
        #expect(controller.theme == .light, "the theme as given; the rows draw it zoomed")
        zoom.resetZoom()
        try await until { controller.tableView.rowHeight == base }
    }
}
