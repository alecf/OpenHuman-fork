import AppKit
import MailFeatures
import MailRender
import MailTheme
import Testing
@testable import MailUIMac

// AppKit closes an event's undo group when the run loop next goes idle; this waits for that point
@MainActor
func runLoopGoesIdle() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let idle = CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, idle, false, .max) { _, _ in done.resume() }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
    }
}

func keyDownEvent(_ key: Character, in window: NSWindow) -> NSEvent? {
    let (characters, code, flags): (String, UInt16, NSEvent.ModifierFlags) = switch key {
    case "\n": ("\r", 36, [])
    case "\t": ("\t", 48, [])
    case "\u{19}": ("\u{19}", 48, .shift)
    case "\u{7f}": ("\u{7f}", 51, [])
    case " ": (" ", 49, [])
    default: (String(key), 0, [])
    }
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 100,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
}

// What TextKit lays out, paragraph by paragraph, after any display substitutions
@MainActor
func shownParagraphs(_ text: NSTextView) -> [NSAttributedString] {
    guard let layout = text.textLayoutManager else { return [] }
    var shown: [NSAttributedString] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
        if let paragraph = fragment.textElement as? NSTextParagraph { shown.append(paragraph.attributedString) }
        return true
    }
    return shown
}

@MainActor
@Suite struct ComposerAutoListTests {
    typealias Doc = RichTextDocument

    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    var undo: UndoManager? { window.undoManager }

    func editor(plain: Bool = false, autoLists: Bool = true) -> ComposerTextView {
        let text = ComposerTextView.make()
        text.configure(with: ComposeTextFlags(continuousSpelling: false, autocorrect: false, grammar: false,
                                              textReplacement: false, quoteSubstitution: false, dashSubstitution: false,
                                              linkDetection: false, writingTools: false, autoLists: autoLists))
        text.bridge = AttributedBridge(font: .systemFont(ofSize: 14))
        text.isPlainTextMode = plain
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(text)
        return text
    }

    func endOfEvent(sourceLocation: SourceLocation = #_sourceLocation) async {
        await runLoopGoesIdle()
        #expect(undo?.groupingLevel == 0, "the event's undo group is closed", sourceLocation: sourceLocation)
    }

    func event(_ body: () -> Void) async {
        body()
        await endOfEvent()
    }

    func typeKeys(_ text: ComposerTextView, _ keys: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(window.makeFirstResponder(text), sourceLocation: sourceLocation)
        for key in keys {
            guard let event = keyDownEvent(key, in: window) else {
                Issue.record("no key event for \(key)", sourceLocation: sourceLocation)
                return
            }
            window.sendEvent(event)
            await endOfEvent(sourceLocation: sourceLocation)
        }
    }

    func backspace(_ text: ComposerTextView) async { await typeKeys(text, "\u{7f}") }

    func undoOnce() async { await event { undo?.undo() } }

    func redoOnce() async { await event { undo?.redo() } }

    func item(_ words: String) -> [Doc.Block] { [.paragraph([.text(words, [])])] }

    func marker(ordered: Bool, _ number: Int) -> String {
        let format = AttributedBridge.markerFormat(ordered: ordered, depth: 0)
        return AttributedBridge.marker(NSTextList(markerFormat: format, options: 0), number: number)
    }

    @Test func oneDotSpaceStartsANumberedListAndReturnContinuesIt() async {
        let text = editor()
        await typeKeys(text, "1. ")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [[]])]))
        #expect(text.string == marker(ordered: true, 1), "the typed 1. became the list's own marker")
        await typeKeys(text, "one\ntwo")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("one"), item("two")])]))
        #expect(text.string == marker(ordered: true, 1) + "one\n" + marker(ordered: true, 2) + "two")
        #expect(text.formatState.list == .numbered)
    }

    @Test func dashAndStarStartBulletedLists() async {
        for typed in ["- ", "* "] {
            let text = editor()
            await typeKeys(text, typed + "milk\neggs")
            #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("milk"), item("eggs")])]), "\(typed)")
            #expect(text.formatState.list == .bullet)
        }
    }

    @Test func numberingStartsAtTheTypedNumberAndIsSentThatWay() async {
        let text = editor()
        await typeKeys(text, "3. three\nfour")
        let document = text.document
        #expect(document == Doc(blocks: [.list(ordered: true, items: [item("three"), item("four")], start: 3)]))
        #expect(text.string.contains(marker(ordered: true, 4) + "four"))
        #expect(ComposeSerializer.html(document, signature: nil).contains("<ol start=\"3\"><li>three</li><li>four</li></ol>"))
        #expect(ComposeSerializer.plainText(document, signature: nil) == "3. three\n4. four")
    }

    @Test func returnOnAnEmptyItemEndsTheList() async {
        let text = editor()
        await typeKeys(text, "- one\ntwo\n\nafter")
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("one"), item("two")]),
                                              .paragraph([.text("after", [])])]))
        #expect(text.formatState.list == nil)
        let html = ComposeSerializer.html(text.document, signature: nil)
        #expect(html.contains("<ul><li>one</li><li>two</li></ul><p style=\"margin:0\">after</p>"), "\(html)")
    }

    @Test func backspaceAtTheStartOfAnItemRemovesItsMarker() async {
        let text = editor()
        await typeKeys(text, "1. ")
        await backspace(text)
        #expect(text.string.isEmpty && text.document == Doc(), "an empty item goes entirely")

        await typeKeys(text, "- one")
        text.setSelectedRange(NSRange(location: (text.string as NSString).range(of: "one").location, length: 0))
        await backspace(text)
        #expect(text.document == Doc(blocks: [.paragraph([.text("one", [])])]), "the text stays")
        #expect(text.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func oneUndoPutsTheTypedMarkerBackAsText() async {
        let text = editor()
        await typeKeys(text, "Intro\n- ")
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .list(ordered: false, items: [[]])]))
        await undoOnce()
        #expect(text.string == "Intro\n- ", "the conversion alone is undone")
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .paragraph([.text("- ", [])])]))
        await redoOnce()
        #expect(text.document == Doc(blocks: [.paragraph([.text("Intro", [])]), .list(ordered: false, items: [[]])]))
    }

    @Test func oneUndoKeepsTheSpaceWhenItStartedNewTyping() async {
        let text = editor()
        await typeKeys(text, "-")
        text.breakUndoCoalescing()
        await typeKeys(text, " ")
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [[]])]))
        await undoOnce()
        #expect(text.string == "- ", "the conversion alone is undone")
        await undoOnce()
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
    func typedListItemsShowTheirTextAfterANumberWithItsPeriod(dark: Bool) async throws {
        let theme = dark ? ThemeTokens.dark : ThemeTokens.light
        let text = editor()
        text.bridge = AttributedBridge(theme: theme)
        await typeKeys(text, "Agenda:\n1. Arrive by nine\nWalk-through\n\n- Bring a laptop\nNotes\n\nThanks")
        #expect(text.document == Doc(blocks: [
            .paragraph([.text("Agenda:", [])]),
            .list(ordered: true, items: [item("Arrive by nine"), item("Walk-through")]),
            .list(ordered: false, items: [item("Bring a laptop"), item("Notes")]),
            .paragraph([.text("Thanks", [])]),
        ]))
        #expect(text.textContentStorage?.includesTextListMarkers == true, "TextKit 2 shows the marker text and adds none")
        let shown = shownParagraphs(text)
        #expect(shown.map(\.string) == ["Agenda:\n", "\t1.\tArrive by nine\n", "\t2.\tWalk-through\n",
                                        "\t•\tBring a laptop\n", "\t•\tNotes\n", "Thanks"],
                "each number is drawn with its period and each item with its text")
        for paragraph in shown where paragraph.string.hasPrefix("\t•\t") {
            let bullet = try #require(paragraph.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
            let words = try #require(paragraph.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.weight(of: bullet) > NSFontManager.shared.weight(of: words),
                    "the bullet is drawn heavier than the text so it reads at text size")
        }
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

    @Test func theFormatBarAndADraftNumberItemsLikeTyping() async throws {
        let typed = editor()
        await typeKeys(typed, "1. one")
        let bar = editor()
        await typeKeys(bar, "one")
        await event { bar.toggleList(ordered: true) }
        let loaded = editor()
        loaded.load(Doc(blocks: [.list(ordered: true, items: [item("one")])]))
        func style(_ text: ComposerTextView) -> NSParagraphStyle? {
            text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        }
        let reference = try #require(style(typed))
        for text in [typed, bar, loaded] {
            #expect(text.string == "\t1.\tone")
            #expect(shownParagraphs(text).map(\.string) == ["\t1.\tone"], "drawn with the period")
            let own = try #require(style(text))
            #expect(own.tabStops.map(\.location) == reference.tabStops.map(\.location))
            #expect(own.tabStops.map(\.alignment) == reference.tabStops.map(\.alignment))
            #expect(own.headIndent == reference.headIndent && own.firstLineHeadIndent == reference.firstLineHeadIndent)
        }
    }

    @Test func returnInTheMiddleRenumbersTheRestAndUndoesInOneStep() async {
        let text = editor()
        await typeKeys(text, "1. a\nb\nc")
        let before = text.string
        text.setSelectedRange(NSRange(location: NSMaxRange((text.string as NSString).range(of: "a")), length: 0))
        await typeKeys(text, "\n")
        #expect(text.string == marker(ordered: true, 1) + "a\n" + marker(ordered: true, 2) + "\n"
                + marker(ordered: true, 3) + "b\n" + marker(ordered: true, 4) + "c")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("a"), [], item("b"), item("c")])]))
        await undoOnce()
        #expect(text.string == before)
    }

    @Test func tabNestsAnItemWithItsOwnNumberingAndShiftTabBringsItBack() async {
        let text = editor()
        await typeKeys(text, "1. one\n")
        await typeKeys(text, "\t")
        await typeKeys(text, "a")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [
            item("one") + [.list(ordered: true, items: [item("a")])],
        ])]), "numbering restarts in the nested list")
        await typeKeys(text, "\u{19}")
        #expect(text.document == Doc(blocks: [.list(ordered: true, items: [item("one"), item("a")])]))
        #expect(text.string.hasSuffix(marker(ordered: true, 2) + "a"))
    }

    @Test func tabInsideTheTextOfAnItemIsATab() async {
        let text = editor()
        await typeKeys(text, "- one")
        await typeKeys(text, "\t")
        #expect(text.string.hasSuffix("one\t"))
    }

    @Test func neverMidLineOrInAQuote() async {
        let text = editor()
        await typeKeys(text, "see 1. this")
        #expect(text.document == Doc(blocks: [.paragraph([.text("see 1. this", [])])]))

        let quoted = editor()
        await event { quoted.toggleQuote() }
        await typeKeys(quoted, "1. ")
        #expect(quoted.document == Doc(blocks: [.quote([.paragraph([.text("1. ", [])])])]))
    }

    @Test func plainTextKeepsLiteralMarkersAndContinuesThem() async {
        let text = editor(plain: true)
        await typeKeys(text, "1. one\ntwo\n\nafter")
        #expect(text.string == "1. one\n2. two\nafter")
        await typeKeys(text, "\n- x\n")
        #expect(text.string == "1. one\n2. two\nafter\n- x\n- ")
        await backspace(text)
        #expect(text.string == "1. one\n2. two\nafter\n- x\n", "backspace after a marker takes the marker")
        #expect(text.document.blocks.allSatisfy { if case .paragraph = $0 { true } else { false } }, "no real list")
        #expect(ComposeSerializer.plainText(text.document, signature: nil).hasPrefix("1. one\n2. two\nafter\n- x"))
    }

    @Test func plainTextTabNestsAndRestartsTheNumbering() async {
        let text = editor(plain: true)
        await typeKeys(text, "1. one\n")
        await typeKeys(text, "\t")
        await typeKeys(text, "a\nb")
        #expect(text.string == "1. one\n   1. a\n   2. b")
        await typeKeys(text, "\u{19}")
        #expect(text.string == "1. one\n   1. a\n2. b")
    }

    @Test func plainTextLeavesQuotesAndTheSignatureAlone() async {
        let text = editor(plain: true)
        await typeKeys(text, "> - quoted\n")
        #expect(text.string == "> - quoted\n")
        await typeKeys(text, "-- \n- sig\n")
        #expect(text.string == "> - quoted\n-- \n- sig\n", "below the signature delimiter")
    }

    @Test func turningTheSettingOffLeavesTypingAlone() async {
        let text = editor(autoLists: false)
        await typeKeys(text, "1. one\n- two")
        #expect(text.document == Doc(blocks: [.paragraph([.text("1. one", [])]), .paragraph([.text("- two", [])])]))
        let plain = editor(plain: true, autoLists: false)
        await typeKeys(plain, "1. one\n")
        #expect(plain.string == "1. one\n")
    }

    @Test func theFormatBarListsAreUnchanged() async {
        let text = editor()
        await typeKeys(text, "word")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        await event { text.toggleList(ordered: false) }
        #expect(text.document == Doc(blocks: [.list(ordered: false, items: [item("word")])]))
        await event { text.toggleList(ordered: false) }
        #expect(text.document == Doc(blocks: [.paragraph([.text("word", [])])]))
    }
}
