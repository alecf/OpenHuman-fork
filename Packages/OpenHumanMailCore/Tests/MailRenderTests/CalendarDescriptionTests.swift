import Foundation
import Testing
@testable import MailRender

@Suite struct CalendarDescriptionTests {
    static let anchor = "<a href=\"https://example.org/go/abc123?token=SAMPLE&amp;skip=true\">https://example.org/go/abc123?token=SAMPLE&amp;skip=true</a>"

    private func links(_ document: RichTextDocument) -> [URL] {
        var found: [URL] = []
        func walk(_ inlines: [RichTextDocument.Inline]) {
            for inline in inlines { if case .link(let url, let inner) = inline { found.append(url); walk(inner) } }
        }
        func blocks(_ list: [RichTextDocument.Block]) {
            for block in list {
                switch block {
                case .paragraph(let inlines): walk(inlines)
                case .list(_, let items, _): items.forEach(blocks)
                case .quote(let inner): blocks(inner)
                case .image: break
                }
            }
        }
        blocks(document.blocks)
        return found
    }

    @Test func entitiesAreDecodedAndNoMarkupShowsAsText() {
        let parsed = CalendarDescription.parse("<p>Fish &amp; chips &lt;3 &mdash; at 6&nbsp;PM</p>")
        #expect(parsed.isHTML)
        #expect(parsed.editableText.contains("Fish & chips <3"))
        #expect(!parsed.editableText.contains("&amp;") && !parsed.editableText.contains("<p>"))
    }

    @Test func anAnchorBecomesALinkWithItsQueryDecoded() {
        let parsed = CalendarDescription.parse(Self.anchor)
        #expect(links(parsed.document) == [URL(string: "https://example.org/go/abc123?token=SAMPLE&skip=true")!])
        #expect(!parsed.editableText.contains("&amp;") && !parsed.editableText.contains("<a "))
        let drawn = CalendarDescription.attributed(parsed.document)
        #expect(drawn.runs.contains { $0.link?.host == "example.org" })
        #expect(!String(drawn.characters).contains("href"))
    }

    @Test func linesParagraphsAndListsKeepTheirShape() {
        let parsed = CalendarDescription.parse("<p>First</p><p>Second<br>line two</p><ul><li>one</li><li>two</li></ul>")
        let text = parsed.editableText
        #expect(text.contains("First") && text.contains("Second\nline two"))
        #expect(text.contains("- one") && text.contains("- two"))
        let drawn = String(CalendarDescription.attributed(parsed.document).characters)
        #expect(drawn.contains("\u{2022} one") && drawn.contains("\u{2022} two"))
    }

    @Test func scriptsStylesFramesAndImagesNeverReachTheText() {
        let hostile = "<p>Hello</p><script>alert('x')</script><style>p{color:red}</style>"
            + "<iframe src=\"https://example.org/frame\"></iframe><img src=\"https://example.org/pixel.gif\">"
            + "<a href=\"javascript:alert(1)\">click</a><a href=\"https://example.org/ok\" onclick=\"evil()\">fine</a>"
        let parsed = CalendarDescription.parse(hostile)
        #expect(parsed.editableText.contains("Hello") && !parsed.editableText.contains("alert") && !parsed.editableText.contains("color:red"))
        #expect(links(parsed.document) == [URL(string: "https://example.org/ok")!], "only the http link survives")
        let hasImage = parsed.document.blocks.contains { if case .image = $0 { true } else { false } }
        #expect(!hasImage, "no image block: nothing remote can load")
        #expect(CalendarDescription.openableURL(URL(string: "javascript:alert(1)")!) == nil)
        #expect(CalendarDescription.openableURL(URL(string: "https://example.org/ok")!) != nil)
    }

    @Test func aDescriptionNobodyEditedIsWrittenBackByteForByte() {
        for original in [Self.anchor, "<p>Fish &amp; chips</p><ul><li>a</li></ul>", "Plain notes\\nsecond line", "", "  spaced  "] {
            let parsed = CalendarDescription.parse(original)
            #expect(CalendarDescription.textToWrite(edited: parsed.editableText, from: parsed) == original)
        }
    }

    @Test func anEditedHTMLDescriptionIsWrittenAsHTMLAndAPlainOneAsPlainText() {
        let html = CalendarDescription.parse("<p>Agenda &amp; notes</p>")
        let written = CalendarDescription.textToWrite(edited: "Agenda & notes\n\nAdded line", from: html)
        #expect(CalendarDescription.looksLikeHTML(written) && written.contains("Added line"))
        #expect(written.contains("&amp;"), "text is escaped, never raw markup")
        let plain = CalendarDescription.parse("Agenda")
        #expect(CalendarDescription.textToWrite(edited: "Agenda\nmore", from: plain) == "Agenda\nmore")
    }

    @Test func icsStyleEscapesRenderAsTheyWereMeant() {
        let parsed = CalendarDescription.parse(#"Bring notes\nRoom 4\, floor 2\; side door\\back"#)
        #expect(!parsed.isHTML)
        #expect(parsed.editableText == "Bring notes\nRoom 4, floor 2; side door\\back")
        #expect(CalendarDescription.unescapeICS("no escapes") == "no escapes")
        #expect(CalendarDescription.unescapeICS("a\\Nb") == "a\nb")
        #expect(CalendarDescription.unescapeICS("odd\\q") == "odd\\q", "an unknown escape is left alone")
    }

    @Test func plainTextAddressesBecomeLinksWithoutTheirClosingPunctuation() {
        let parsed = CalendarDescription.parse("Join at https://example.org/room/7, then relax.")
        #expect(links(parsed.document) == [URL(string: "https://example.org/room/7")!])
        #expect(parsed.editableText == "Join at https://example.org/room/7, then relax.")
    }

    @Test func htmlIsRecognisedByItsTagsNotByAnAngleBracket() {
        #expect(CalendarDescription.looksLikeHTML("<b>x</b>") && CalendarDescription.looksLikeHTML("a<br>b"))
        #expect(!CalendarDescription.looksLikeHTML("5 < 6 and 7 > 3") && !CalendarDescription.looksLikeHTML("mail <sam@example.org>"))
    }
}
