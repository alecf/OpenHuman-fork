import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMIME

private func message(_ tweak: (inout OutgoingMessage) -> Void = { _ in }) -> OutgoingMessage {
    var m = OutgoingMessage(
        from: EmailAddress(name: "Alice", email: "alice@example.com"),
        to: [EmailAddress(name: "Bob", email: "bob@example.org")], cc: [EmailAddress(email: "cc@example.org")],
        bcc: [EmailAddress(name: "Secret", email: "secret@example.net")], replyTo: [],
        subject: "Hello", htmlBody: nil, textBody: "Hi Bob", attachments: [],
        inReplyTo: nil, references: [], messageID: "<oh.fixed@example.com>",
        date: Date(timeIntervalSince1970: 1_791_617_400), extraHeaders: [])
    tweak(&m)
    return m
}

private func lines(_ data: Data) -> [String] {
    String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
}

private func counter() -> () -> String {
    nonisolated(unsafe) var n = 0
    return { n += 1; return "oh-test\(n)" }
}

@Suite struct MIMEBuilderTests {
    @Test func goldenTextOnly() throws {
        let data = try MIMEBuilder.build(message(), bcc: .strip)
        let expected = [
            "MIME-Version: 1.0", "Date: Sat, 10 Oct 2026 07:30:00 +0000", "Message-ID: <oh.fixed@example.com>",
            "From: Alice <alice@example.com>", "To: Bob <bob@example.org>", "Cc: cc@example.org", "Subject: Hello",
            "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable", "", "Hi Bob",
        ].joined(separator: "\r\n")
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test func goldenFullStructure() throws {
        let m = message {
            $0.htmlBody = "<p>Hi <img src=\"cid:logo\"></p>"
            $0.textBody = nil
            $0.attachments = [
                OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "logo", isInline: true),
                OutgoingAttachment(filename: "résumé.pdf", mimeType: "application/pdf", data: Data("pdf".utf8), isInline: false),
            ]
        }
        let text = String(decoding: try MIMEBuilder.build(m, bcc: .includeForGmailSubmission, boundary: counter()), as: UTF8.self)
        let expected = """
            MIME-Version: 1.0
            Date: Sat, 10 Oct 2026 07:30:00 +0000
            Message-ID: <oh.fixed@example.com>
            From: Alice <alice@example.com>
            To: Bob <bob@example.org>
            Cc: cc@example.org
            Bcc: Secret <secret@example.net>
            Subject: Hello
            Content-Type: multipart/mixed; boundary="oh-test1"

            --oh-test1
            Content-Type: multipart/alternative; boundary="oh-test2"

            --oh-test2
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Hi
            --oh-test2
            Content-Type: multipart/related; boundary="oh-test3"

            --oh-test3
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            <p>Hi <img src=3D"cid:logo"></p>
            --oh-test3
            Content-Type: image/png; name="logo.png"
            Content-Transfer-Encoding: base64
            Content-Disposition: inline; filename="logo.png"
            Content-ID: <logo>

            AQID
            --oh-test3--

            --oh-test2--

            --oh-test1
            Content-Type: application/pdf; name="=?UTF-8?B?csOpc3Vtw6kucGRm?="
            Content-Transfer-Encoding: base64
            Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf

            cGRm
            --oh-test1--

            """.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(text == expected)
    }

    @Test func bcc() throws {
        let m = message()
        let stripped = try MIMEBuilder.build(m, bcc: .strip)
        #expect(!lines(stripped).contains { $0.lowercased().hasPrefix("bcc:") })
        #expect(!String(decoding: stripped, as: UTF8.self).contains("secret@example.net"))
        let submitted = try MIMEBuilder.build(m, bcc: .includeForGmailSubmission)
        #expect(lines(submitted).contains("Bcc: Secret <secret@example.net>"))
        #expect(try MIMEParser.parse(rfc822: submitted).bcc.map(\.email) == ["secret@example.net"])
        #expect(try MIMEParser.parse(rfc822: stripped).bcc.isEmpty)
        // Why: an extra header must not smuggle Bcc past .strip
        for name in ["Bcc", "bCC", "Resent-Bcc", "From", "Content-Type"] {
            #expect(throws: MIMEError.invalidHeader("reserved header \(name)")) {
                try MIMEBuilder.build(message { $0.extraHeaders = [MIMEHeaderField(name: name, value: "x")] }, bcc: .strip)
            }
        }
    }

    @Test func agentMarkers() throws {
        let m = message {
            $0.extraHeaders = [MIMEHeaderField(name: "X-OpenHuman-Origin", value: "agent"),
                               MIMEHeaderField(name: "x-openhuman-run", value: "42"),
                               MIMEHeaderField(name: "X-Other", value: "keep")]
        }
        let draft = try MIMEBuilder.build(m, bcc: .includeForGmailSubmission)
        #expect(lines(draft).contains("X-OpenHuman-Origin: agent"))
        let final = try MIMEBuilder.build(m.removingAgentMarkers(), bcc: .includeForGmailSubmission)
        #expect(!lines(final).contains { $0.lowercased().hasPrefix("x-openhuman-") })
        #expect(lines(final).contains("X-Other: keep"))
        #expect(m.removingAgentMarkers().extraHeaders == [MIMEHeaderField(name: "X-Other", value: "keep")])
    }

    @Test func headerInjectionIsRejected() {
        func fails(_ tweak: (inout OutgoingMessage) -> Void) {
            #expect(throws: MIMEError.self) { try MIMEBuilder.build(message(tweak), bcc: .strip) }
        }
        fails { $0.subject = "hi\r\nBcc: evil@example.net" }
        fails { $0.subject = "hi\nX: y" }
        fails { $0.to = [EmailAddress(email: "a@example.org\r\nBcc: e@x")] }
        fails { $0.to = [EmailAddress(name: "n\r\nBcc: e@x", email: "a@example.org")] }
        fails { $0.to = [EmailAddress(email: "a@example.org>, <evil@x")] }
        fails { $0.from = EmailAddress(email: "no-at-sign") }
        fails { $0.extraHeaders = [MIMEHeaderField(name: "X-A", value: "v\r\nBcc: e@x")] }
        fails { $0.extraHeaders = [MIMEHeaderField(name: "X A", value: "v")] }
        fails { $0.extraHeaders = [MIMEHeaderField(name: "X-A:", value: "v")] }
        fails { $0.messageID = "<a b>" }
        fails { $0.inReplyTo = "<a>\r\nBcc: e@x" }
        fails { $0.attachments = [OutgoingAttachment(filename: "a\r\nb", mimeType: "text/plain", data: Data(), isInline: false)] }
        fails { $0.attachments = [OutgoingAttachment(filename: "a", mimeType: "text/plain\r\nX: y", data: Data(), isInline: false)] }
        fails { $0.attachments = [OutgoingAttachment(filename: "a", mimeType: "text/plain", data: Data(), contentID: "x>\r\nX: y", isInline: true)] }
    }

    @Test func missingBodyAndSizeLimit() {
        #expect(throws: MIMEError.missingBody) { try MIMEBuilder.build(message { $0.textBody = nil }, bcc: .strip) }
        let big = OutgoingAttachment(filename: "big.bin", mimeType: "application/octet-stream",
                                     data: Data(count: 36 * 1024 * 1024), isInline: false)
        #expect(throws: MIMEError.tooLarge(bytes: 36 * 1024 * 1024 + 6)) {
            try MIMEBuilder.build(message { $0.attachments = [big] }, bcc: .strip)
        }
    }

    @Test func nonASCIIHeadersAndLineLengths() throws {
        let longSubject = String(repeating: "Überraschung für die Familie ", count: 12)
        let m = message {
            $0.subject = longSubject
            $0.from = EmailAddress(name: "Zoë “Z” Ünal", email: "zoe@example.com")
            $0.to = [EmailAddress(name: "Doe, John \"JD\"", email: "jd@example.org"),
                     EmailAddress(name: "Ünal", email: "u@example.org")]
            $0.textBody = String(repeating: "ünïcode line with = signs and trailing space \n", count: 40) + String(repeating: "x", count: 500)
            $0.references = (1...30).map { "<ref\($0)@example.com>" }
            $0.extraHeaders = [MIMEHeaderField(name: "X-Note", value: "héllo")]
        }
        let data = try MIMEBuilder.build(m, bcc: .strip)
        for line in lines(data) { #expect(line.utf8.count <= 78 + 20, "\(line.count)") ; #expect(line.utf8.count <= 998) }
        let encodedLines = lines(data).filter { $0.hasPrefix("=?") || $0.contains("=?UTF-8?B?") }
        for l in encodedLines { #expect(l.utf8.count <= 80) }
        let parsed = try MIMEParser.parse(rfc822: data)
        #expect(parsed.subject == longSubject)
        #expect(parsed.from?.name == "Zoë “Z” Ünal")
        #expect(parsed.to.first?.name == "Doe, John \"JD\"" && parsed.to.count == 2)
        #expect(parsed.textBody?.replacingOccurrences(of: "\r\n", with: "\n") == m.textBody)
        #expect(parsed.references.count == 30)
        #expect(parsed.headers["X-Note"] == "héllo")
    }

    @Test func htmlOnlyGetsTextAlternative() throws {
        let m = message { $0.textBody = nil; $0.htmlBody = "<p>Hello <b>there</b></p><p>second</p>" }
        let parsed = try MIMEParser.parse(rfc822: try MIMEBuilder.build(m, bcc: .strip))
        #expect(parsed.textBody?.replacingOccurrences(of: "\r\n", with: "\n") == "Hello there\nsecond")
        #expect(parsed.htmlBody == m.htmlBody)
    }

    @Test func boundaryNeverCollidesWithContent() throws {
        let m = message { $0.textBody = "--oh-test1\n--oh-test2\nfoo"; $0.attachments = [
            OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8), isInline: false)] }
        let data = try MIMEBuilder.build(m, bcc: .strip, boundary: counter())
        #expect(String(decoding: data, as: UTF8.self).contains("boundary=\"oh-test3\""))
        #expect(try MIMEParser.parse(rfc822: data).attachments.count == 1)
        #expect(throws: MIMEError.self) { try MIMEBuilder.build(m, bcc: .strip, boundary: { "oh-test1" }) }
    }

    @Test func randomBoundaryShape() throws {
        let text = String(decoding: try MIMEBuilder.build(message { $0.attachments = [
            OutgoingAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8), isInline: false)] }, bcc: .strip), as: UTF8.self)
        #expect(text.contains(try Regex("boundary=\"oh-[0-9a-f]{32}\"")))
    }

    private static let words = ["Hello", "wörld", "日本語", "ñandú", "emoji😀", "a=b", "=?x", "quote\"d", "back\\slash", "semi;colon",
                                "(paren)", "tab", "x", "long" + String(repeating: "word", count: 30), "é"]

    private func randomText(_ rng: inout SeededGenerator, max: Int) -> String {
        let n = Int.random(in: 1...max, using: &rng)
        var out = ""
        for i in 0..<n {
            out += Self.words.randomElement(using: &rng)!
            out += i == n - 1 ? "" : [" ", " ", "  ", "\n", "\n\n", " \n"].randomElement(using: &rng)!
        }
        return out
    }

    private func randomName(_ rng: inout SeededGenerator) -> String? {
        if Bool.random(using: &rng) { return nil }
        let w = ["Ann", "Bob", "Zoë", "O'Neil", "Doe, Jane", "J. R. R.", "Müller", "山田", "\"Q\"", "a@b"]
        return (0..<Int.random(in: 1...3, using: &rng)).map { _ in w.randomElement(using: &rng)! }.joined(separator: " ")
    }

    private func randomAddresses(_ rng: inout SeededGenerator, _ maxCount: Int) -> [EmailAddress] {
        (0..<Int.random(in: 0...maxCount, using: &rng)).map { i in
            EmailAddress(name: randomName(&rng), email: "user\(Int.random(in: 0..<1000, using: &rng))\(i)@ex\(i).example")
        }
    }

    @Test func randomMessagesRoundTrip() throws {
        var rng = SeededGenerator(seed: 2026)
        for round in 0..<250 {
            let wantsHTML = Bool.random(using: &rng)
            let wantsText = !wantsHTML || Bool.random(using: &rng)
            var attachments: [OutgoingAttachment] = []
            for k in 0..<Int.random(in: 0...3, using: &rng) {
                let inline = wantsHTML && Bool.random(using: &rng)
                let size = Int.random(in: 0...3000, using: &rng)
                attachments.append(OutgoingAttachment(
                    filename: ["a.txt", "résumé \(k).pdf", "日本語.png", "x\"y.bin", String(repeating: "long name ", count: 12) + "é.dat"].randomElement(using: &rng)!,
                    mimeType: ["application/pdf", "image/png", "text/plain", "application/octet-stream"].randomElement(using: &rng)!,
                    data: Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }),
                    contentID: inline ? "cid\(k)@example.com" : nil, isInline: inline))
            }
            let m = OutgoingMessage(
                from: EmailAddress(name: randomName(&rng), email: "from@example.com"),
                to: randomAddresses(&rng, 4), cc: randomAddresses(&rng, 3), bcc: randomAddresses(&rng, 2),
                replyTo: randomAddresses(&rng, 1),
                subject: randomText(&rng, max: 8).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces),
                htmlBody: wantsHTML ? "<p>" + randomText(&rng, max: 30) + "</p>" : nil,
                textBody: wantsText ? randomText(&rng, max: 30) : nil,
                attachments: attachments,
                inReplyTo: Bool.random(using: &rng) ? "<irt\(round)@example.com>" : nil,
                references: (0..<Int.random(in: 0...4, using: &rng)).map { "<r\($0)@example.com>" },
                messageID: "<oh.\(round)@example.com>",
                date: Date(timeIntervalSince1970: Double(Int.random(in: 1_000_000_000...1_900_000_000, using: &rng))),
                extraHeaders: Bool.random(using: &rng) ? [MIMEHeaderField(name: "X-OpenHuman-Origin", value: randomText(&rng, max: 4).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))] : [])
            let data = try MIMEBuilder.build(m, bcc: .includeForGmailSubmission)
            let p = try MIMEParser.parse(rfc822: data)
            func norm(_ s: String?) -> String? { s?.replacingOccurrences(of: "\r\n", with: "\n") }
            #expect(p.subject == m.subject, "round \(round)")
            #expect(p.from == m.from && p.to == m.to && p.cc == m.cc && p.bcc == m.bcc && p.replyTo == m.replyTo, "round \(round)")
            #expect(p.messageID == m.messageID && p.inReplyTo == m.inReplyTo && p.references == m.references)
            #expect(p.date == m.date)
            #expect(norm(p.htmlBody) == norm(m.htmlBody), "round \(round)")
            if let t = m.textBody { #expect(norm(p.textBody) == norm(t), "round \(round)") }
            else { #expect(p.textBody != nil) }
            #expect(p.attachments.count == m.attachments.count, "round \(round)")
            for (a, b) in zip(p.attachments.sorted { $0.size < $1.size || ($0.size == $1.size && $0.filename < $1.filename) },
                              m.attachments.sorted { $0.data.count < $1.data.count || ($0.data.count == $1.data.count && $0.filename < $1.filename) }) {
                #expect(a.filename == b.filename && a.mimeType == b.mimeType && a.inlineData == b.data && a.isInline == b.isInline
                        && a.contentID == b.contentID, "round \(round) \(b.filename)")
            }
            #expect(p.warnings.isEmpty, "round \(round): \(p.warnings)")
            #expect(p.headers["X-OpenHuman-Origin"] == m.extraHeaders.first?.value)
            let stripped = try MIMEBuilder.build(m, bcc: .strip)
            #expect(!lines(stripped).contains { $0.lowercased().hasPrefix("bcc:") })
            #expect(try MIMEParser.parse(rfc822: stripped).bcc.isEmpty)
        }
    }
}
