import Foundation
import Testing
@testable import MailRender

private typealias Doc = RichTextDocument

@Suite struct ComposePasteTests {
    @Test func richPasteKeepsTheComposersStructureAndDropsStyling() {
        let html = "<meta charset=\"utf-8\"><b style=\"font-weight:normal;\" id=\"docs-internal-guid-1\">"
            + "<p dir=\"ltr\"><span style=\"font-family:Arial;color:#ff0000;font-weight:700\">Bold</span>"
            + "<span style=\"font-style:italic\"> and italic</span></p>"
            + "<p><span style=\"text-decoration:underline\">under</span> "
            + "<a href=\"https://example.com/a?utm_source=news&amp;id=7&amp;fbclid=x\">link</a></p>"
            + "<ul><li>one</li><li><strong style=\"font-weight:400\">two</strong></li></ul></b>"
        let pasted = ComposePaste.document(fromHTML: html)
        #expect(pasted.document.blocks == [
            .paragraph([.text("Bold", .bold), .text(" and italic", .italic)]),
            .paragraph([.text("under", .underline), .text(" ", []),
                        .link(URL(string: "https://example.com/a?id=7")!, [.text("link", [])])]),
            .list(ordered: false, items: [[.paragraph([.text("one", [])])], [.paragraph([.text("two", [])])]]),
        ], "\(pasted.document.blocks)")
        #expect(pasted.report.removedParameters == 2)
        #expect(!pasted.report.isWorthTelling, "removing tracking parameters is not worth a word")
    }

    @Test func hiddenTextImagesAndInvisiblePaddingAreLeftOut() {
        let html = "<div style=\"display: none; max-height:0\">Preheader\u{200B}\u{200B}</div><p hidden>also hidden</p>"
            + "<p>Hello\u{200B} <img src=\"https://t.example/open.gif\" width=\"1\" height=\"1\">world</p>"
            + "<p style=\"mso-hide: all\">Outlook only</p><p><img src=\"cid:part1@x\" alt=\"Logo\"></p>"
            + "<p>\u{200B}\u{FEFF}</p>"
        let pasted = ComposePaste.document(fromHTML: html)
        #expect(pasted.document.blocks == [.paragraph([.text("Hello world", [])])], "\(pasted.document.blocks)")
        #expect(pasted.report.droppedHidden == 3)
        #expect(pasted.report.droppedImages == 2, "a pixel and another message's cid: part")
        #expect(pasted.report.isWorthTelling)
    }

    @Test func linksStayLinksAndLoseOnlyTheDocumentedParameters() {
        let html = "<p><a href=\"https://u1.ct.sendgrid.net/ls/click?upn=abc\">Read the report</a> and "
            + "<a href=\"https://example.org/post?utm_medium=email&amp;mc_eid=abc&amp;utm_campaign=x#top\">the post</a> or "
            + "<a href=\"mailto:dana@example.com\">Dana</a> <a href=\"javascript:alert(1)\">not a link</a></p>"
        let pasted = ComposePaste.document(fromHTML: html)
        #expect(pasted.document.blocks == [.paragraph([
            .link(URL(string: "https://u1.ct.sendgrid.net/ls/click?upn=abc")!, [.text("Read the report", [])]),
            .text(" and ", []), .link(URL(string: "https://example.org/post?mc_eid=abc#top")!, [.text("the post", [])]),
            .text(" or ", []), .link(URL(string: "mailto:dana@example.com")!, [.text("Dana", [])]),
            .text(" not a link", []),
        ])], "\(pasted.document.blocks)")
        #expect(pasted.report == ComposePaste.Report(removedParameters: 2))
    }

    @Test func onlyTheDocumentedParametersAreRemovedByTheirExactNames() {
        func cleaned(_ raw: String) -> (String, Int) {
            let result = ComposePaste.cleanedLink(URL(string: raw)!)
            return (result.url.absoluteString, result.removedParameters)
        }
        #expect(cleaned("https://example.com/p?id=1&utm_source=x&b=%20c") == ("https://example.com/p?id=1&b=%20c", 1))
        #expect(cleaned("https://example.com/p?gclid=1&gbraid=2&wbraid=3&gad_source=4&dclid=5&fbclid=6&ttclid=7&_kx=8"
                        + "&mkt_tok=9&utm_term=10") == ("https://example.com/p", 10))
        #expect(cleaned("https://example.com/p?id=1") == ("https://example.com/p?id=1", 0))
        let unconfirmed = "https://example.com/p?msclkid=1&_hsenc=2&_hsmi=3&hsa_acc=4&mc_cid=5&mc_eid=6&gad_campaignid=7"
        #expect(cleaned(unconfirmed) == (unconfirmed, 0))
        #expect(cleaned("https://example.com/p?UTM_Source=x&GCLID=y") == ("https://example.com/p?UTM_Source=x&GCLID=y", 0))
        #expect(cleaned("https://mailtrack.io/trace/link/abc") == ("https://mailtrack.io/trace/link/abc", 0))
        #expect(cleaned("mailto:someone@example.com?subject=utm_source") == ("mailto:someone@example.com?subject=utm_source", 0),
                "only web links are cleaned")
    }

    @Test func theListsAreTheResearchNotesAndTheUnconfirmedOnesAreNotApplied() {
        #expect(ComposePaste.trackingParameterPrefixes == ["utm_"])
        #expect(ComposePaste.trackingParameters
            == ["gclid", "gbraid", "wbraid", "gad_source", "dclid", "fbclid", "ttclid", "_kx", "mkt_tok"])
        #expect(ComposePaste.unconfirmedTrackingParameters.isDisjoint(with: ComposePaste.trackingParameters))
        for name in ComposePaste.unconfirmedTrackingParameters { #expect(!ComposePaste.isTrackingParameter(name), "\(name)") }
        #expect(!ComposePaste.isTrackingParameter("hsa_cam"), "an unconfirmed prefix is not applied")
        #expect(ComposePaste.isTrackingParameter("utm_content") && ComposePaste.isTrackingParameter("_kx"))
    }

    @Test func plainPasteKeepsTheTextAndDropsOnlyInvisiblePadding() {
        #expect(ComposePaste.plainText("a\u{200B}b\r\nc\u{FEFF}\rd\u{00AD}e") == "ab\nc\nde")
        let family = "👩\u{200D}👩\u{200D}👧"
        #expect(ComposePaste.plainText(family) == family)
        #expect(ComposePaste.plainText("می\u{200C}خواهم") == "می\u{200C}خواهم")
    }

    @Test func cleaningAPastedDocumentKeepsItsLinksAndImagesAndCountsWhatWent() {
        let doc = Doc(blocks: [
            .paragraph([.text("\u{2060}", [])]),
            .paragraph([.link(URL(string: "https://pstmrk.it/3s/x?ttclid=1")!, [.text("tracked", .bold)])]),
            .image(InlineImageRef(contentID: "a@openhuman")),
            .quote([.paragraph([.text("q\u{200B}", [])])]),
        ])
        let cleaned = ComposePaste.clean(doc)
        #expect(cleaned.document.blocks == [
            .paragraph([.link(URL(string: "https://pstmrk.it/3s/x")!, [.text("tracked", .bold)])]),
            .image(InlineImageRef(contentID: "a@openhuman")),
            .quote([.paragraph([.text("q", [])])]),
        ])
        #expect(cleaned.report == ComposePaste.Report(removedParameters: 1))
        #expect(ComposePaste.Report(droppedImages: 1) + ComposePaste.Report(removedParameters: 2, droppedHidden: 1)
            == ComposePaste.Report(removedParameters: 2, droppedImages: 1, droppedHidden: 1))
    }

    @Test func aStoredDraftIsImportedAsBefore() {
        let stored = "<div dir=\"auto\"><p style=\"margin:0\"><span style=\"font-weight:700\">x</span></p>"
            + "<p style=\"margin:0\" hidden>kept</p><img src=\"cid:c1@x\" alt=\"Chart\"></div>"
            + "<div class=\"gmail_quote\" data-oh-quote=\"1\">quote</div>"
        #expect(ComposeSerializer.importHTML(stored) == Doc(blocks: [
            .paragraph([.text("x", [])]), .paragraph([.text("kept", [])]),
            .image(InlineImageRef(contentID: "c1@x", alt: "Chart")),
        ]))
    }

    @Test func inlineImagesAreFoundAndOrphansLeaveTheSentHTML() {
        let doc = Doc(blocks: [
            .paragraph([.text("Look", [])]),
            .image(InlineImageRef(contentID: "a@x", width: 10, height: 10)),
            .list(ordered: false, items: [[.paragraph([.text("item", [])]), .image(InlineImageRef(contentID: "b@x"))]]),
            .quote([.image(InlineImageRef(contentID: "c@x"))]),
        ])
        #expect(doc.inlineImageIDs == ["a@x", "b@x", "c@x"])
        let kept = doc.keepingImages(["a@x"])
        #expect(kept.inlineImageIDs == ["a@x"])
        let html = ComposeSerializer.html(kept, signature: nil)
        #expect(html.contains("cid:a@x") && !html.contains("cid:b@x") && !html.contains("cid:c@x"))
        #expect(ComposeSerializer.plainText(kept, signature: nil).contains("[image]"))
    }
}
