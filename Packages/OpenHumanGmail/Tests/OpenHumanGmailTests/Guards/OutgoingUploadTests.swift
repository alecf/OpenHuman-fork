import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct OutgoingUploadTests {
    private static let insertURL = GmailRequests.upload + "messages?uploadType=multipart&internalDateSource=receivedTime"
    private static let boundary = "oh_upload_0123456789abcdef"
    private static let message = GmailRequests.message([
        "From: OpenHuman Test <test@openhuman.invalid>",
        "To: me@example.com",
        "Subject: [OpenHuman test] run1 1",
        "Date: Sat, 10 Oct 2026 12:00:00 +0000",
        "Message-ID: <oh-test.run1.1@openhuman.invalid>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 7bit",
    ], body: "Synthetic test message 1 of run run1. It contains no real content.\r\n")

    @Test func aWellFormedUploadParsesIntoItsTwoParts() throws {
        let meta = #"{"labelIds":["Label_T"]}"#
        let upload = try Upload.parse(GmailRequests.upload("POST", Self.insertURL, metadata: meta, message: Self.message)).get()
        #expect(upload.metadata == Data(meta.utf8))
        #expect(upload.message == Self.message)
        let lf = Data(String(decoding: Self.message, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
        #expect(try Upload.parse(GmailRequests.upload("POST", Self.insertURL, metadata: meta, message: lf)).get().message == lf)
    }

    @Test func malformedUploadBodiesAreRefused() {
        let meta = #"{"labelIds":["Label_T"]}"#
        let b = Self.boundary
        let url = Self.insertURL
        let synthetic = Self.message
        var inside = synthetic
        inside.append(Data("\r\n--\(b)\r\nContent-Type: message/rfc822\r\n\r\nsmuggled".utf8))
        var bare = synthetic
        bare.append(Data("x--\(b)".utf8))
        let cases: [(String, HTTPRequest)] = [
            ("three parts", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                 extraPart: "Content-Type: message/rfc822\r\n\r\n" + "x")),
            ("preamble", GmailRequests.upload("POST", url, metadata: meta, message: synthetic, preamble: "hello\r\n")),
            ("epilogue", GmailRequests.upload("POST", url, metadata: meta, message: synthetic, epilogue: "\r\nmore")),
            ("no close delimiter", GmailRequests.request("POST", url, body: Data("--\(b)\r\nContent-Type: application/json\r\n\r\n\(meta)".utf8),
                                                         extraHeaders: ["Content-Type": "multipart/related; boundary=\(b)"])),
            ("boundary inside the message", GmailRequests.upload("POST", url, metadata: meta, message: inside)),
            ("bare boundary inside the message", GmailRequests.upload("POST", url, metadata: meta, message: bare)),
            ("LF line ends", GmailRequests.upload("POST", url, metadata: meta, message: synthetic, newline: "\n")),
            ("base64 metadata", GmailRequests.upload("POST", url, metadata: "eyJsYWJlbElkcyI6WyJMYWJlbF9UIl19", message: synthetic,
                                                     metaHeaders: "Content-Type: application/json\r\nContent-Transfer-Encoding: base64")),
            ("base64 message", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                    messageHeaders: "Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64")),
            ("parts swapped", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                   metaHeaders: "Content-Type: message/rfc822",
                                                   messageHeaders: "Content-Type: application/json")),
            ("metadata without Content-Type", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                                   metaHeaders: "Content-ID: <1>")),
            ("extra part header", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                       metaHeaders: "Content-Type: application/json\r\nX-Goog-Thing: 1")),
            ("folded part header", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                        metaHeaders: "Content-Type:\r\n application/json")),
            ("multipart/mixed", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                     contentType: "multipart/mixed; boundary=\(b)")),
            ("no boundary", GmailRequests.upload("POST", url, metadata: meta, message: synthetic, contentType: "multipart/related")),
            ("wrong boundary", GmailRequests.upload("POST", url, metadata: meta, message: synthetic,
                                                    contentType: "multipart/related; boundary=other")),
            ("JSON content type", GmailRequests.upload("POST", url, metadata: meta, message: synthetic, contentType: "application/json")),
            ("empty body", GmailRequests.request("POST", url, extraHeaders: ["Content-Type": "multipart/related; boundary=x"])),
        ]
        for (label, request) in cases {
            #expect(throws: Upload.Refusal.self, "\(label)") { _ = try Upload.parse(request).get() }
        }
    }
}
