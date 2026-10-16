import Foundation
import Testing
@testable import MailRender

@Suite struct ListStartTests {
    typealias Doc = RichTextDocument

    static let fromThree = Doc(blocks: [.list(ordered: true, items: [[.paragraph([.text("third", [])])],
                                                                      [.paragraph([.text("fourth", [])])]], start: 3)])

    @Test func aNumberedListKeepsItsFirstNumberInHTMLAndPlainText() {
        let html = ComposeSerializer.html(Self.fromThree, signature: nil)
        #expect(html.contains("<ol start=\"3\"><li>third</li><li>fourth</li></ol>"), "\(html)")
        #expect(ComposeSerializer.plainText(Self.fromThree, signature: nil) == "3. third\n4. fourth")
        #expect(String(CalendarDescription.attributed(Self.fromThree).characters) == "3. third\n4. fourth")
    }

    @Test func oneAndBulletListsCarryNoStart() {
        let item: [[Doc.Block]] = [[.paragraph([.text("a", [])])]]
        let one = Doc(blocks: [.list(ordered: true, items: item, start: 1)])
        #expect(one.normalized == Doc(blocks: [.list(ordered: true, items: item)]))
        #expect(ComposeSerializer.html(one, signature: nil).contains("<ol><li>a</li></ol>"))
        let bullets = Doc(blocks: [.list(ordered: false, items: item, start: 4)])
        #expect(bullets.normalized == Doc(blocks: [.list(ordered: false, items: item)]))
        #expect(ComposeSerializer.html(bullets, signature: nil).contains("<ul><li>a</li></ul>"))
        #expect(ComposeSerializer.plainText(bullets, signature: nil) == "- a")
    }

    @Test func theStartSurvivesTheDraftRoundTrip() {
        let back = ComposeSerializer.importHTML(ComposeSerializer.html(Self.fromThree, signature: nil))
        #expect(back == Self.fromThree.normalized, "\(back)")
        let odd = ComposeSerializer.importHTML("<ol start=\"0\"><li>x</li></ol><ol start=\"abc\"><li>y</li></ol>"
                                               + "<ol start=\" 12 \"><li>z</li></ol>")
        #expect(odd.blocks == [
            .list(ordered: true, items: [[.paragraph([.text("x", [])])]]),
            .list(ordered: true, items: [[.paragraph([.text("y", [])])]]),
            .list(ordered: true, items: [[.paragraph([.text("z", [])])]], start: 12),
        ])
        #expect(ComposeSerializer.importHTML("<ul start=\"5\"><li>b</li></ul>").blocks
                == [.list(ordered: false, items: [[.paragraph([.text("b", [])])]])])
    }

    @Test func aListWithoutAStartEncodesAsBefore() throws {
        let plain = Doc(blocks: [.list(ordered: true, items: [[.paragraph([.text("a", [])])]])])
        let data = try JSONEncoder().encode(plain)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("start"), "older builds read it unchanged")
        #expect(try JSONDecoder().decode(Doc.self, from: data) == plain)
        #expect(try JSONDecoder().decode(Doc.self, from: JSONEncoder().encode(Self.fromThree)) == Self.fromThree)
    }
}
