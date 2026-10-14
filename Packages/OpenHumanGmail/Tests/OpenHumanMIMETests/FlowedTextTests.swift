import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMIME

private let paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut "
    + "labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation."

@Suite struct FlowedTextTests {
    @Test func encodeSoftWrapsLongLinesAtSeventyEight() {
        let encoded = FlowedText.encode(paragraph)
        let lines = encoded.components(separatedBy: "\n")
        #expect(lines.count == 3)
        for line in lines { #expect(line.count <= 78) }
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(" ") }, "every soft break ends with its space")
        #expect(!lines.last!.hasSuffix(" "), "the paragraph's end is a hard break")
        #expect(lines.joined() == paragraph, "DelSp=no: joining the lines gives the text back")
    }

    @Test func encodeStuffsAndKeepsQuotesAndTheSignatureSeparator() {
        let text = "From the start\n leading space\n>not ours\n> > nested \(paragraph)\n\n-- \nSam"
        let encoded = FlowedText.encode(text).components(separatedBy: "\n")
        #expect(encoded[0] == " From the start" && encoded[1] == "  leading space")
        #expect(encoded[2] == "> not ours", "a composer quote line keeps its depth with the canonical prefix")
        #expect(encoded[3].hasPrefix(">> nested ") && encoded[3].hasSuffix(" ") && encoded[3].count <= 78)
        #expect(encoded.dropFirst(3).prefix(while: { $0.hasPrefix(">>") }).count >= 2, "a quoted paragraph wraps inside its quote")
        #expect(encoded.suffix(3) == ["", "-- ", "Sam"], "the separator keeps its space and is never a soft break")
    }

    @Test func aLongWordIsNeverCut() {
        let link = "https://example.com/" + String(repeating: "x", count: 120)
        let lines = FlowedText.encode("see \(link) now").components(separatedBy: "\n")
        #expect(lines.contains(link + " ") || lines.contains(link))
        #expect(FlowedText.decode(lines.joined(separator: "\n"), delSp: false) == "see \(link) now")
    }

    @Test func decodeJoinsSoftBreaksAndRemovesStuffing() {
        #expect(FlowedText.decode("Hello \r\nworld\r\n From here", delSp: false) == "Hello world\nFrom here")
        #expect(FlowedText.decode("> quoted \n> on two\n>> deeper", delSp: false) == "> quoted on two\n> > deeper")
        #expect(FlowedText.decode("日本語の長い \n文章です。", delSp: true) == "日本語の長い文章です。")
        #expect(FlowedText.decode("Line \n-- \nSig", delSp: false) == "Line \n-- \nSig", "a separator never joins")
        #expect(FlowedText.decode("Line\n-- \nSig", delSp: false) == "Line\n-- \nSig")
    }

    @Test func roundTripsTheComposersText() {
        for text in [paragraph, "> \(paragraph)", "> > \(paragraph)\n> one\nzero", "a  b  c \(paragraph)", "", "line\n\n-- \nSig",
                     "From me\n>quoted"] {
            let expected = text.components(separatedBy: "\n").map { line -> String in
                guard line != "-- " else { return line }
                var trimmed = line
                while trimmed.hasSuffix(" ") { trimmed.removeLast() }
                let (depth, content) = FlowedText.composerQuote(trimmed)
                return depth == 0 ? trimmed : String(repeating: "> ", count: depth) + content
            }.joined(separator: "\n")
            #expect(FlowedText.decode(FlowedText.encode(text), delSp: false) == expected, "\(text.prefix(30))")
        }
    }

    @Test func theParserKeepsTheTextPartsParameters() throws {
        func parse(_ contentType: String) throws -> ParsedMessage {
            let raw = "From: a@example.com\r\nSubject: s\r\nContent-Type: \(contentType)\r\n\r\nSoft \r\nbreak\r\n"
            return try MIMEParser.parse(rfc822: Data(raw.utf8))
        }
        #expect(try parse("text/plain; charset=utf-8; format=flowed").textFormat == .flowed(delSp: false))
        #expect(try parse("text/plain; format=Flowed; DelSp=Yes").textFormat == .flowed(delSp: true))
        #expect(try parse("text/plain; charset=utf-8").textFormat == .fixed)
        #expect(try parse("text/html; format=flowed").textFormat == .fixed, "no text part")
        let alternative = """
            From: a@example.com\r\nContent-Type: multipart/alternative; boundary="b"\r\n\r\n--b\r\n\
            Content-Type: text/plain; format=flowed\r\n\r\nSoft \r\nbreak\r\n--b\r\nContent-Type: text/html\r\n\r\n<p>x</p>\r\n--b--\r\n
            """
        let parsed = try MIMEParser.parse(rfc822: Data(alternative.utf8))
        #expect(parsed.textFormat == .flowed(delSp: false) && parsed.htmlBody != nil)
    }

    @Test func aFlowedSendRoundTripsThroughTheParser() throws {
        let text = "Hi Bob,\n\n\(paragraph)\n\n> \(paragraph)\n\n-- \nAlice"
        let outgoing = OutgoingMessage(
            from: EmailAddress(name: "Alice", email: "alice@example.com"), to: [EmailAddress(email: "bob@example.org")],
            cc: [], bcc: [], replyTo: [], subject: "Plain", htmlBody: nil, textBody: text, attachments: [],
            references: [], messageID: "<oh.flowed@example.com>", date: Date(timeIntervalSince1970: 1_791_617_400),
            extraHeaders: [], textFormat: .flowed(delSp: false))
        let data = try MIMEBuilder.build(outgoing, bcc: .strip)
        let raw = String(decoding: data, as: UTF8.self)
        #expect(raw.contains("Content-Type: text/plain; charset=utf-8; format=flowed"))
        #expect(raw.contains("=20\r\n"), "quoted-printable keeps each soft break's space")
        let parsed = try MIMEParser.parse(rfc822: data)
        #expect(parsed.textFormat == .flowed(delSp: false) && parsed.htmlBody == nil)
        #expect(FlowedText.decode(try #require(parsed.textBody), delSp: false) == text)
        var fixed = outgoing
        fixed.textFormat = .fixed
        #expect(!String(decoding: try MIMEBuilder.build(fixed, bcc: .strip), as: UTF8.self).contains("format=flowed"))
    }
}
