import Foundation
import MailModel
import Testing
@testable import MailRender

struct PlainFixture: CustomTestStringConvertible, Sendable {
    let name: String
    let text: String
    let format: PlainTextFormat
    let expected: String
    var testDescription: String { name }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/plain")

    static let all: [PlainFixture] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(load)
    }()

    static func load(_ url: URL) -> PlainFixture? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = raw.components(separatedBy: "\n")
        guard let header = lines.first, header.hasPrefix("# plain-fixture:") else { return nil }
        lines.removeFirst()
        let format: PlainTextFormat
        if header.contains("format=flowed-delsp") {
            format = .flowed(delSp: true)
        } else if header.contains("format=flowed") {
            format = .flowed(delSp: false)
        } else {
            format = .fixed
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard let expected = try? String(contentsOf: directory.appendingPathComponent("expected/\(name).txt"), encoding: .utf8)
        else { return nil }
        return PlainFixture(name: name, text: decode(lines.joined(separator: "\n")), format: format,
                            expected: expected.trimmingCharacters(in: .newlines))
    }

    static func decode(_ text: String) -> String {
        text.replacingOccurrences(of: "␠", with: " ").replacingOccurrences(of: "␍", with: "\r")
    }
}

func outline(_ layout: PlainTextLayout) -> String {
    var out: [String] = []
    for (index, line) in layout.lines.enumerated() {
        if index == layout.foldStart { out.append("•••") }
        let tag = switch line.role {
        case .body: ""
        case .quote(let depth): String(repeating: ">", count: depth)
        case .signature: "--"
        }
        out.append(tag + "|" + visibleTrailingSpaces(line.text))
    }
    return out.joined(separator: "\n")
}

func visibleTrailingSpaces(_ text: String) -> String {
    var kept = Substring(text)
    var spaces = 0
    while kept.last == " " {
        kept = kept.dropLast()
        spaces += 1
    }
    return String(kept) + String(repeating: "␠", count: spaces)
}

@Test func plainFixtureCorpusIsPresent() {
    #expect(PlainFixture.all.count >= 15, "found \(PlainFixture.all.count) in \(PlainFixture.directory.path)")
    #expect(PlainFixture.all.contains { $0.format == .flowed(delSp: false) })
    #expect(PlainFixture.all.contains { $0.format == .flowed(delSp: true) })
}

@Test(arguments: PlainFixture.all)
func plainFixtureMatchesItsHandWrittenLayout(_ fixture: PlainFixture) throws {
    let rendered = MessageRenderer().render(MessageContent(html: nil, text: fixture.text),
                                            context: RenderContext(textFormat: fixture.format))
    guard case .plain(let document) = rendered else {
        Issue.record("\(fixture.name): not rendered as plain text")
        return
    }
    let actual = outline(PlainTextLayout(document))
    if actual != fixture.expected {
        let e = fixture.expected.components(separatedBy: "\n"), a = actual.components(separatedBy: "\n")
        let line = zip(e, a).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(e.count, a.count)
        Issue.record("""
            \(fixture.name) differs from plain/expected/\(fixture.name).txt at line \(line + 1):
              expected: \(line < e.count ? e[line] : "<end>")
              actual:   \(line < a.count ? a[line] : "<end>")
            """)
    }
}

@Test func blankLinesBetweenRunsAreCounted() {
    let doc = PlainTextDocument.parse("\n\nIntro\n\n\n> quoted\n>\n\nAfter\n")
    #expect(doc.blocks == [.body("Intro"), .quote("quoted", depth: 1), .body("After")])
    #expect(doc.blankLinesBefore == [2, 2, 2], "two above Intro, two before the quote, a quoted and a plain blank line")
    #expect(doc.blankLines(before: 0) == 0, "the top of the message never gets blank lines")
    #expect(doc.blankLines(before: 1) == 2)
}

@Test func runsMeetWithoutAnAddedBlankLine() {
    let layout = PlainTextLayout(PlainTextDocument.parse("> q\na\n>> deeper\nb"))
    #expect(layout.lines == [
        .init(text: "q", role: .quote(depth: 1)),
        .init(text: "a", role: .body),
        .init(text: "deeper", role: .quote(depth: 2)),
        .init(text: "b", role: .body),
    ])
    #expect(layout.foldStart == nil, "quotes between answers stay visible")
}

@Test func aDocumentWithoutBlankLineCountsKeepsTheEarlierSpacing() {
    let layout = PlainTextLayout(PlainTextDocument(blocks: [.body("a"), .quote("q", depth: 1)]))
    #expect(layout.lines.map(\.text) == ["a", "", "q"])
    #expect(layout.foldStart == 2)
}

@Test func emptyQuotedLinesKeepTheirDepthAndTheSignatureKeepsItsSeparator() {
    let layout = PlainTextLayout(PlainTextDocument.parse("Hi\n> one\n>\n> two\n-- \nSam"))
    #expect(layout.lines.map(\.depth) == [0, 1, 1, 1, 0, 0])
    #expect(layout.lines[2] == .init(text: "", role: .quote(depth: 1)), "the bar runs through a blank quoted line")
    #expect(layout.lines.suffix(2).map(\.role) == [.signature, .signature])
    #expect(layout.lines[4].text == "-- ")
    #expect(layout.foldStart == 1, "the trailing history and the signature fold from the first quoted line")
}

@Test func quoteIndentFollowsTheDesignAndStopsAtSixLevels() {
    #expect(PlainTextLayout.quoteIndent == 12 && PlainTextLayout.quoteBarWidth == 2)
    #expect(PlainTextLayout.indent(depth: 0) == 0)
    #expect(PlainTextLayout.indent(depth: 2) == 24)
    #expect(PlainTextLayout.indent(depth: 9) == 72)
}

@Test func anEmptyMessageHasNoLines() {
    let layout = PlainTextLayout(PlainTextDocument.parse("\n\n  \n"))
    #expect(layout.lines.isEmpty && layout.foldStart == nil)
}
