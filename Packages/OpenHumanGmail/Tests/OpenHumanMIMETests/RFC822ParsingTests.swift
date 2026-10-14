import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMIME

func crlf(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

enum Fixture {
    static let plain = """
        From: Alice Example <alice@example.com>
        To: bob@example.org, "Carol, C" <carol@example.org>
        Cc: =?UTF-8?B?w4lsw6k=?= <ele@example.org>
        Subject: =?UTF-8?Q?Caf=C3=A9?= planning
        Date: Fri, 10 Oct 2026 09:30:00 +0200
        Message-ID: <m1@example.com>
        In-Reply-To: <m0@example.com>
        References: <a@example.com> <m0@example.com>
        List-Id: <list.example.com>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9 at nine=2E Soft=
        break and =3D sign.
        """

    static let latin1QP = """
        From: a@example.com
        Subject: x
        Content-Type: text/plain; charset="iso-8859-1"
        Content-Transfer-Encoding: quoted-printable

        caf=E9 cr=e8me
        """

    static let alternativeWithAttachment = """
        From: a@example.com
        To: b@example.org
        Subject: Report
        Content-Type: multipart/mixed; boundary="outer"

        preamble ignored
        --outer
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain; charset=utf-8

        plain version
        --alt
        Content-Type: multipart/related; boundary="rel"; start="<root@x>"

        --rel
        Content-Type: image/png
        Content-ID: <logo@x>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --rel
        Content-Type: text/html; charset=utf-8
        Content-ID: <root@x>

        <p>html <img src="cid:logo@x"></p>
        --rel--
        --alt--
        --outer
        Content-Type: application/pdf; name="fallback.pdf"
        Content-Disposition: attachment; filename*0*=UTF-8''r%C3%A9sum%C3%A9-; filename*1*=final.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        JQ==
        --outer--
        epilogue
        """

    static let embeddedMessage = """
        From: a@example.com
        Subject: fwd
        Content-Type: multipart/mixed; boundary=b1

        --b1
        Content-Type: text/plain

        see attached
        --b1
        Content-Type: message/rfc822

        From: z@example.com
        Subject: =?UTF-8?Q?Inner_subject?=
        Content-Type: text/plain

        inner body
        --b1--
        """

    static let invite = """
        From: a@example.com
        Subject: meet
        Content-Type: multipart/alternative; boundary=c
        
        --c
        Content-Type: text/plain

        Meeting
        --c
        Content-Type: text/calendar; method=REQUEST; charset=utf-8

        BEGIN:VCALENDAR
        END:VCALENDAR
        --c--
        """
}

@Suite struct RFC822ParsingTests {
    @Test func plainQuotedPrintableMessage() throws {
        let m = try MIMEParser.parse(rfc822: crlf(Fixture.plain))
        #expect(m.subject == "Café planning")
        #expect(m.from == EmailAddress(name: "Alice Example", email: "alice@example.com"))
        #expect(m.to == [EmailAddress(email: "bob@example.org"), EmailAddress(name: "Carol, C", email: "carol@example.org")])
        #expect(m.cc.first?.name == "Élé")
        #expect(m.messageID == "<m1@example.com>" && m.inReplyTo == "<m0@example.com>")
        #expect(m.references == ["<a@example.com>", "<m0@example.com>"])
        #expect(m.listID == "<list.example.com>")
        #expect(m.date == Date(timeIntervalSince1970: 1_791_617_400))
        #expect(m.textBody == "Café at nine. Softbreak and = sign.")
        #expect(m.htmlBody == nil && m.attachments.isEmpty && m.warnings.isEmpty)
    }

    @Test func latin1Body() throws {
        let m = try MIMEParser.parse(rfc822: crlf(Fixture.latin1QP))
        #expect(m.textBody == "café crème")
    }

    @Test func nestedRelatedAlternativeMixed() throws {
        let m = try MIMEParser.parse(rfc822: crlf(Fixture.alternativeWithAttachment))
        #expect(m.textBody == "plain version")
        #expect(m.htmlBody == "<p>html <img src=\"cid:logo@x\"></p>")
        #expect(m.attachments.count == 2)
        let logo = try #require(m.attachments.first { $0.contentID == "logo@x" })
        #expect(logo.isInline && logo.mimeType == "image/png" && logo.inlineData?.count == 8 && logo.size == 8)
        let pdf = try #require(m.attachments.first { $0.mimeType == "application/pdf" })
        #expect(pdf.filename == "résumé-final.pdf")
        #expect(!pdf.isInline && pdf.inlineData == Data("%PDF-1.4\n%".utf8))
        #expect(pdf.partID == "1" && logo.partID == "0.1.0")
    }

    @Test func embeddedMessageIsAnAttachmentNamedAfterItsSubject() throws {
        let m = try MIMEParser.parse(rfc822: crlf(Fixture.embeddedMessage))
        #expect(m.textBody == "see attached")
        let eml = try #require(m.attachments.first)
        #expect(eml.mimeType == "message/rfc822" && eml.filename == "Inner subject.eml")
        #expect(String(decoding: eml.inlineData ?? Data(), as: UTF8.self).contains("inner body"))
    }

    @Test func calendarPart() throws {
        let m = try MIMEParser.parse(rfc822: crlf(Fixture.invite))
        #expect(m.calendarParts.count == 1 && m.calendarParts[0].contains("BEGIN:VCALENDAR"))
        #expect(m.attachments.first?.filename == "invite.ics")
        #expect(m.textBody == "Meeting")
    }

    @Test func lfOnlyLineEndsAndNoTrailingNewline() throws {
        let m = try MIMEParser.parse(rfc822: Data("Subject: s\nContent-Type: text/plain\n\nbody".utf8))
        #expect(m.subject == "s" && m.textBody == "body")
    }

    @Test func foldedHeadersAndBase64Body() throws {
        let raw = "Subject: one\r\n two\r\n\tthree\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\nw6l0w6k"
        let m = try MIMEParser.parse(rfc822: Data(raw.utf8))
        #expect(m.subject == "one two\tthree" && m.textBody == "été")
    }

    @Test func malformedStructureBecomesWarnings() throws {
        let noBoundary = try MIMEParser.parse(rfc822: crlf("Subject: s\nContent-Type: multipart/mixed\n\nhello"))
        #expect(noBoundary.textBody == "hello" && !noBoundary.warnings.isEmpty)
        let unterminated = try MIMEParser.parse(rfc822: crlf("Subject: s\nContent-Type: multipart/mixed; boundary=q\n\n--q\nContent-Type: text/plain\n\nhi"))
        #expect(unterminated.textBody == "hi" && unterminated.warnings.contains("multipart not terminated"))
        #expect(throws: MIMEError.self) { try MIMEParser.parse(rfc822: Data()) }
        #expect(throws: MIMEError.self) { try MIMEParser.parse(rfc822: Data("no headers here".utf8)) }
    }

    @Test func transferDecoders() {
        #expect(TransferEncoding.quotedPrintable(Array("a=3D=3d b  \r\nc=\r\nd=zz".utf8)[...]) == Data("a== b\r\ncd=zz".utf8))
        #expect(TransferEncoding.base64(Array("SGVs\r\nbG8".utf8)[...]) == Data("Hello".utf8))
        #expect(TransferEncoding.base64(Array("!!!!".utf8)[...]).isEmpty)
    }

    @Test func rfc2231Parameters() {
        let p = ContentType.parse("attachment; filename*=UTF-8''%E2%82%AC%20rates.pdf; name=\"a\\\"b\"")
        #expect(p.params["filename"] == "€ rates.pdf" && p.params["name"] == "a\"b")
        let latin = ContentType.parse("x; filename*=iso-8859-1'en'caf%E9.txt")
        #expect(latin.params["filename"] == "café.txt")
    }

    @Test func deepNestingIsBounded() throws {
        var raw = "Subject: deep\r\nContent-Type: multipart/mixed; boundary=b0\r\n\r\n"
        let depth = 3000
        for i in 0..<depth {
            raw += "--b\(i)\r\nContent-Type: multipart/mixed; boundary=b\(i + 1)\r\n\r\n"
        }
        raw += "--b\(depth)\r\nContent-Type: text/plain\r\n\r\nleaf\r\n"
        let m = try MIMEParser.parse(rfc822: Data(raw.utf8))
        #expect(m.warnings.contains { $0.contains("too deep") })
    }

    @Test func deepGmailPayloadIsBounded() throws {
        var part = GmailPayloadPart(partID: "x", mimeType: "text/plain", headers: [], data: Base64URL.encode(Data("x".utf8)), parts: [])
        for _ in 0..<300 { part = GmailPayloadPart(mimeType: "multipart/mixed", headers: [], parts: [part]) }
        let m = try MIMEParser.parse(gmailPayload: part)
        #expect(m.warnings.contains("nesting too deep"))
    }

    @Test func manyPartsAreCapped() throws {
        var raw = "Subject: many\r\nContent-Type: multipart/mixed; boundary=m\r\n\r\n"
        for _ in 0..<(RFC822.maxParts + 500) { raw += "--m\r\nContent-Type: text/plain\r\n\r\nx\r\n" }
        raw += "--m--\r\n"
        let m = try MIMEParser.parse(rfc822: Data(raw.utf8))
        #expect(m.warnings.contains("too many parts; rest ignored"))
    }

    @Test func manyHeadersAreCapped() throws {
        let raw = String(repeating: "X-A: 1\r\n", count: 50_000) + "\r\nbody"
        let m = try MIMEParser.parse(rfc822: Data(raw.utf8))
        #expect(m.headers.fields.count == RFC822.maxHeaders)
    }

    @Test func hugeBodyAndOversizedInput() throws {
        let big = Data(repeating: 0x41, count: 12 * 1024 * 1024)
        let raw = Data("Subject: big\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n".utf8)
            + Data(big.base64EncodedString(options: .lineLength76Characters).utf8)
        let m = try MIMEParser.parse(rfc822: raw)
        #expect(m.attachments.first?.size == big.count)
        let tooBig = Data(count: RFC822.maxInputBytes + 1)
        #expect(throws: MIMEError.tooLarge(bytes: RFC822.maxInputBytes + 1)) { try MIMEParser.parse(rfc822: tooBig) }
    }

    @Test func badCharsetsNeverCrash() throws {
        for label in ["x-bogus", "\"\"", "utf-7", "UTF-16", "iso-2022-jp", "euc-kr", "💥", String(repeating: "a", count: 10_000)] {
            let raw = "Subject: s\r\nContent-Type: text/plain; charset=\(label)\r\n\r\n" + "bytes \u{FF}\u{FE}"
            var data = Data(raw.utf8)
            data.append(contentsOf: [0xFF, 0xFE, 0x00, 0x80, 0xC3])
            let m = try MIMEParser.parse(rfc822: data)
            #expect(m.textBody != nil)
        }
    }

    @Test func randomBytesNeverCrash() {
        var rng = SeededGenerator(seed: 42)
        let seeds = [Fixture.plain, Fixture.alternativeWithAttachment, Fixture.embeddedMessage, Fixture.invite]
        for round in 0..<300 {
            var bytes = [UInt8](crlf(seeds[round % seeds.count]))
            for _ in 0..<(1 + round % 20) {
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: bytes[i] = UInt8.random(in: 0...255, using: &rng)
                case 1: bytes.remove(at: i)
                default: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: i)
                }
            }
            _ = try? MIMEParser.parse(rfc822: Data(bytes))
        }
        for _ in 0..<100 {
            let n = Int.random(in: 1..<2000, using: &rng)
            _ = try? MIMEParser.parse(rfc822: Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
