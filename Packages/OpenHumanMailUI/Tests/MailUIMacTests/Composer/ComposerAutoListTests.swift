import AppKit
import MailFeatures
import MailRender
import MailTheme
import Testing
@testable import MailUIMac

// Grouped by event as in the app, so a keystroke opens a group only when it registers something and typing coalesces;
// no run loop pass ends the event here, so the open group is closed by hand
@MainActor
final class EventUndoHost: NSObject, NSTextViewDelegate {
    let manager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { manager }

    func event(_ body: () -> Void) {
        body()
        if manager.groupingLevel > 0 { manager.endUndoGrouping() }
    }
}

@MainActor
@Suite struct ComposerAutoListTests {
    typealias Doc = RichTextDocument

    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let host = EventUndoHost()

    init() { window.isReleasedWhenClosed = false }

    func editor(plain: Bool = false, autoLists: Bool = true) -> ComposerTextView {
        let text = ComposerTextView.make()
        text.configure(with: ComposeTextFlags(continuousSpelling: false, autocorrect: false, grammar: false,
                                              textReplacement: false, quoteSubstitution: false, dashSubstitution: false,
                                              linkDetection: false, writingTools: false, autoLists: autoLists))
        text.bridge = AttributedBridge(font: .systemFont(ofSize: 14))
        text.isPlainTextMode = plain
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        text.delegate = host
        window.contentView?.addSubview(text)
        return text
    }

    func typeKeys(_ text: ComposerTextView, _ keys: String) {
        for key in keys {
            host.event {
                if key == "\n" {
                    text.insertNewline(nil)
                } else {
                    text.insertText(String(key), replacementRange: text.selectedRange())
                }
            }
        }
    }

    func backspace(_ text: ComposerTextView) { host.event { text.deleteBackward(nil) } }

    func item(_ words: String) -> [Doc.Block] { [.paragraph([.text(words, [])])] }

    func marker(ordered: Bool, _ number: Int) -> String {
        AttributedBridge.marker(NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0), number: number)
    }

    @Test func oneDotSpaceStartsANumberedListAndReturnContinuesIt() {
        let text = editor()
        typeKeys(text, "1. ")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [[]])]))
        #expect(text.string == marker(ordered: true, 1), "the typed 1. became the list's own marker")
        typeKeys(text, "one\ntwo")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("one"), item("two")])]))
        #expect(text.string == marker(ordered: true, 1) + "one\n" + marker(ordered: true, 2) + "two")
        #expect(text.formatState.list == .numbered)
    }

    @Test func dashAndStarStartBulletedLists() {
        for typed in ["- ", "* "] {
            let text = editor()
            typeKeys(text, typed + "milk\neggs")
            #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("milk"), item("eggs")])]), "\(typed)")
            #expect(text.formatState.list == .bullet)
        }
    }

    @Test func numberingStartsAtTheTypedNumberAndIsSentThatWay() {
        let text = editor()
        typeKeys(text, "3. three\nfour")
        let document = text.document
        #expect(document == Doc(blocks: [.list(ordered: true, items: [item("three"), item("four")], start: 3)]))
        #expect(text.string.contains(marker(ordered: true, 4) + "four"))
        #expect(ComposeSerializer.html(document, signature: nil).contains("<ol start=\"3\"><li>three</li><li>four</li></ol>"))
        #expect(ComposeSerializer.plainText(document, signature: nil) == "3. three\n4. four")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        let text = editor()
        typeKeys(text, "- one\ntwo\n\nafter")
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("one"), item("two")]),
                                              .paragraph([.text("after", [])])]))
        #expect(text.formatState.list == nil)
        let html = ComposeSerializer.html(text.document, signature: nil)
        #expect(html.contains("<ul><li>one</li><li>two</li></ul><p style=\"margin:0\">after</p>"), "\(html)")
    }

    @Test func backspaceAtTheStartOfAnItemRemovesItsMarker() {
        let text = editor()
        typeKeys(text, "1. ")
        backspace(text)
        #expect(text.string.isEmpty && text.document == Doc(), "an empty item goes entirely")

        typeKeys(text, "- one")
        text.setSelectedRange(NSRange(location: (text.string as NSString).range(of: "one").location, length: 0))
        backspace(text)
        #expect(text.document == Doc(blocks: [.paragraph([.text("one", [])])]), "the text stays")
        #expect(text.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func oneUndoPutsTheTypedMarkerBackAsText() {
        let text = editor()
        typeKeys(text, "Intro\n- ")
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .list(ordered: false, items: [[]])]))
        host.manager.undo()
        #expect(text.string == "Intro\n- ", "the conversion alone is undone")
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .paragraph([.text("- ", [])])]))
        host.manager.redo()
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .list(ordered: false, items: [[]])]))
    }

    @Test func oneUndoKeepsTheSpaceWhenItStartedNewTyping() {
        let text = editor()
        typeKeys(text, "-")
        text.breakUndoCoalescing()
        typeKeys(text, " ")
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [[]])]))
        host.manager.undo()
        #expect(text.string == "- ", "the conversion alone is undone")
        host.manager.undo()
        #expect(text.string == "-", "then the space")
    }

    func layoutFrames(_ text: ComposerTextView, of range: NSRange) -> [CGRect] {
        guard let layout = text.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        layout.ensureLayout(for: layout.documentRange)
        var frames: [CGRect] = []
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        return frames
    }

    @Test(arguments: [false, true])
    func typedListItemsShowTheirTextAfterANumberWithItsPeriod(dark: Bool) throws {
        let theme = dark ? ThemeTokens.dark : ThemeTokens.light
        let text = editor()
        text.bridge = AttributedBridge(theme: theme)
        typeKeys(text, "Agenda:\n1. Arrive by nine\nWalk-through\n\n- Bring a laptop\nNotes\n\nThanks")
        #expect(text.document == Doc(blocks: [
            .paragraph([.text("Agenda:", [])]),
            .list(ordered: true, items: [item("Arrive by nine"), item("Walk-through")]),
            .list(ordered: false, items: [item("Bring a laptop"), item("Notes")]),
            .paragraph([.text("Thanks", [])]),
        ]))
        #expect(text.textContentStorage?.includesTextListMarkers == true, "TextKit 2 shows the marker text and adds none")
        let storage = try #require(text.textStorage)
        let ns = storage.string as NSString
        let background = theme.component.compose.bg
        for (shown, words) in [("1.", "Arrive by nine"), ("2.", "Walk-through"), ("•", "Bring a laptop"), ("•", "Notes")] {
            let content = ns.range(of: words)
            try #require(content.location != NSNotFound, "\(words)")
            let line = ns.paragraphRange(for: content)
            let marker = NSRange(location: line.location, length: content.location - line.location)
            #expect(ns.substring(with: marker) == "\t\(shown)\t")
            let style = try #require(storage.attribute(.paragraphStyle, at: content.location, effectiveRange: nil)
                as? NSParagraphStyle)
            #expect(style.textLists.count == 1 && style.headIndent == 24 && style.firstLineHeadIndent == 0)
            #expect(style.tabStops.map(\.alignment) == [.right, .left])
            #expect(style.tabStops.map(\.location) == [18, 24], "the marker ends before the text, which starts at the indent")

            var colors: [NSColor?] = []
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: line.location,
                                                                     length: NSMaxRange(content) - line.location)) { value, _, _ in
                colors.append(value as? NSColor)
            }
            for color in colors {
                let rgb = try #require(color?.usingColorSpace(.sRGB), "every run of \(words) has a text colour")
                let ink = ThemeColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent),
                                     blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
                #expect(ink.contrastRatio(on: background) >= 4.5, "\(words) is readable on the composer")
            }

            let textFrames = layoutFrames(text, of: content)
            let markerFrames = layoutFrames(text, of: marker)
            let laid = textFrames.reduce(CGRect.null) { $0.union($1) }
            let markerLaid = markerFrames.reduce(CGRect.null) { $0.union($1) }
            #expect(!textFrames.isEmpty && !markerFrames.isEmpty && laid.width > 0, "\(words) is laid out")
            #expect(abs(laid.minX - style.headIndent) < 1 && laid.maxX <= text.bounds.width, "\(words) starts at the indent")
            #expect(textFrames.allSatisfy { abs($0.minY - markerLaid.minY) < 1 }, "\(words) is on its marker's line")
            #expect(markerLaid.minX >= 0 && markerLaid.maxX <= style.headIndent + 0.5, "the marker stays left of the text")
        }
    }

    @Test func theFormatBarAndADraftNumberItemsLikeTyping() throws {
        let typed = editor()
        typeKeys(typed, "1. one")
        let bar = editor()
        typeKeys(bar, "one")
        host.event { bar.toggleList(ordered: true) }
        let loaded = editor()
        loaded.load(Doc(blocks: [.list(ordered: true, items: [item("one")])]))
        func style(_ text: ComposerTextView) -> NSParagraphStyle? {
            text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        }
        let reference = try #require(style(typed))
        for text in [typed, bar, loaded] {
            #expect(text.string == "\t1.\tone")
            let own = try #require(style(text))
            #expect(own.tabStops.map(\.location) == reference.tabStops.map(\.location))
            #expect(own.tabStops.map(\.alignment) == reference.tabStops.map(\.alignment))
            #expect(own.headIndent == reference.headIndent && own.firstLineHeadIndent == reference.firstLineHeadIndent)
        }
    }

    @Test func returnInTheMiddleRenumbersTheRestAndUndoesInOneStep() {
        let text = editor()
        typeKeys(text, "1. a\nb\nc")
        let before = text.string
        text.setSelectedRange(NSRange(location: NSMaxRange((text.string as NSString).range(of: "a")), length: 0))
        typeKeys(text, "\n")
        #expect(text.string == marker(ordered: true, 1) + "a\n" + marker(ordered: true, 2) + "\n"
                + marker(ordered: true, 3) + "b\n" + marker(ordered: true, 4) + "c")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("a"), [], item("b"), item("c")])]))
        host.manager.undo()
        #expect(text.string == before)
    }

    @Test func tabNestsAnItemWithItsOwnNumberingAndShiftTabBringsItBack() {
        let text = editor()
        typeKeys(text, "1. one\n")
        host.event { text.insertTab(nil) }
        typeKeys(text, "a")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [
            item("one") + [.list(ordered: true, items: [item("a")])],
        ])]), "numbering restarts in the nested list")
        host.event { text.insertBacktab(nil) }
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("one"), item("a")])]))
        #expect(text.string.hasSuffix(marker(ordered: true, 2) + "a"))
    }

    @Test func tabInsideTheTextOfAnItemIsATab() {
        let text = editor()
        typeKeys(text, "- one")
        host.event { text.insertTab(nil) }
        #expect(text.string.hasSuffix("one\t"))
    }

    @Test func neverMidLineOrInAQuote() {
        let text = editor()
        typeKeys(text, "see 1. this")
        #expect(text.document == Doc(blocks: [.paragraph([.text("see 1. this", [])])]))

        let quoted = editor()
        host.event { quoted.toggleQuote() }
        typeKeys(quoted, "1. ")
        #expect(quoted.document == Doc(blocks: [.quote([.paragraph([.text("1. ", [])])])]))
    }

    @Test func plainTextKeepsLiteralMarkersAndContinuesThem() {
        let text = editor(plain: true)
        typeKeys(text, "1. one\ntwo\n\nafter")
        #expect(text.string == "1. one\n2. two\nafter")
        typeKeys(text, "\n- x\n")
        #expect(text.string == "1. one\n2. two\nafter\n- x\n- ")
        backspace(text)
        #expect(text.string == "1. one\n2. two\nafter\n- x\n", "backspace after a marker takes the marker")
        #expect(text.document.blocks.allSatisfy { if case .paragraph = $0 { true } else { false } }, "no real list")
        #expect(ComposeSerializer.plainText(text.document, signature: nil).hasPrefix("1. one\n2. two\nafter\n- x"))
    }

    @Test func plainTextTabNestsAndRestartsTheNumbering() {
        let text = editor(plain: true)
        typeKeys(text, "1. one\n")
        host.event { text.insertTab(nil) }
        typeKeys(text, "a\nb")
        #expect(text.string == "1. one\n   1. a\n   2. b")
        host.event { text.insertBacktab(nil) }
        #expect(text.string == "1. one\n   1. a\n2. b")
    }

    @Test func plainTextLeavesQuotesAndTheSignatureAlone() {
        let text = editor(plain: true)
        typeKeys(text, "> - quoted\n")
        #expect(text.string == "> - quoted\n")
        typeKeys(text, "-- \n- sig\n")
        #expect(text.string == "> - quoted\n-- \n- sig\n", "below the signature delimiter")
    }

    @Test func turningTheSettingOffLeavesTypingAlone() {
        let text = editor(autoLists: false)
        typeKeys(text, "1. one\n- two")
        #expect(text.document == Doc(blocks: [.paragraph([.text("1. one", [])]), .paragraph([.text("- two", [])])]))
        let plain = editor(plain: true, autoLists: false)
        typeKeys(plain, "1. one\n")
        #expect(plain.string == "1. one\n")
    }

    @Test func theFormatBarListsAreUnchanged() {
        let text = editor()
        typeKeys(text, "word")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        host.event { text.toggleList(ordered: false) }
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("word")])]))
        host.event { text.toggleList(ordered: false) }
        #expect(text.document == Doc(blocks: [.paragraph([.text("word", [])])]))
    }
}
