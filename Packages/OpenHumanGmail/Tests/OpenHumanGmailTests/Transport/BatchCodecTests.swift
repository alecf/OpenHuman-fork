import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct BatchCodecTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func part(_ id: String, status: Int = 200, json: String = "{\"id\":\"x\"}", eol: String = "\r\n") -> String {
        "Content-Type: application/http\(eol)Content-ID: <response-\(id)>\(eol)\(eol)"
            + "HTTP/1.1 \(status) X\(eol)Content-Type: application/json; charset=UTF-8\(eol)Content-Length: \(json.utf8.count)\(eol)\(eol)\(json)"
    }

    @Test func builderOutputPassesReadOnlyInspectionAndHasTheDocumentedShape() throws {
        let parts = [BatchPartRequest(contentID: "item-0", target: "/gmail/v1/users/me/messages/a?format=metadata&metadataHeaders=From"),
                     BatchPartRequest(contentID: "item-1", target: "/gmail/v1/users/me/threads/b?format=minimal")]
        let boundary = BatchCodec.makeBoundary()
        let body = BatchCodec.body(parts: parts, boundary: boundary)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("Content-ID: <item-0>\r\n\r\nGET /gmail/v1/users/me/messages/a?format=metadata&metadataHeaders=From HTTP/1.1\r\n\r\n"))
        #expect(text.hasSuffix("--\(boundary)--\r\n"))
        #expect(boundary.hasPrefix("batch_"))
        var request = HTTPRequest(method: "POST", url: BatchCodec.endpoint,
                                  headers: ["Content-Type": BatchCodec.contentType(boundary: boundary)], body: body)
        #expect(ReadOnlyTransport.refusalReason(for: request) == nil)
        request.headers["Content-Type"] = "multipart/mixed; boundary=other"
        #expect(ReadOnlyTransport.refusalReason(for: request) != nil)
    }

    @Test func targetIsPathAndQueryOnly() {
        let url = GmailClient.url("/gmail/v1/users/me/messages/a b", query: [("format", "metadata"), ("metadataHeaders", "From")])
        #expect(BatchCodec.target(for: url) == "/gmail/v1/users/me/messages/a%20b?format=metadata&metadataHeaders=From")
    }

    @Test func parsesCRLFResponses() throws {
        let body = "--b1\r\n\(part("item-0"))\r\n--b1\r\n\(part("item-1", status: 404, json: "{\"error\":{\"code\":404}}"))\r\n--b1--\r\n"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(body)))
        #expect(parts.map(\.contentID) == ["item-0", "item-1"])
        #expect(parts.map(\.status) == [200, 404])
        #expect(String(decoding: parts[0].body, as: UTF8.self) == "{\"id\":\"x\"}")
        #expect(parts[1].headers["content-type"] == "application/json; charset=UTF-8")
    }

    @Test func parsesLFOnlyResponses() throws {
        let body = "--b1\n\(part("item-0", eol: "\n"))\n--b1\n\(part("item-1", eol: "\n"))\n--b1--\n"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(body)))
        #expect(parts.map(\.contentID) == ["item-0", "item-1"])
        #expect(parts.allSatisfy { String(decoding: $0.body, as: UTF8.self) == "{\"id\":\"x\"}" })
    }

    @Test func toleratesAMissingTrailingBoundary() throws {
        let body = "--b1\r\n\(part("item-0"))\r\n--b1\r\n\(part("item-1"))\r\n"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(body)))
        #expect(parts.map(\.contentID) == ["item-0", "item-1"])
        #expect(parts.allSatisfy { String(decoding: $0.body, as: UTF8.self) == "{\"id\":\"x\"}" })
    }

    @Test func aTruncatedLastPartKeepsWhatArrivedAndDropsUnreadableOnes() throws {
        let cut = "--b1\r\n\(part("item-0"))\r\n--b1\r\nContent-Type: application/http\r\nContent-ID: <response-item-1>\r\n\r\nHTT"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(cut)))
        #expect(parts.map(\.contentID) == ["item-0"])
    }

    @Test func partsOutOfOrderCarryTheirContentIDs() throws {
        let body = "--b1\r\n\(part("item-2"))\r\n--b1\r\n\(part("item-0"))\r\n--b1\r\n\(part("item-1"))\r\n--b1--"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(body)))
        #expect(parts.map(\.contentID) == ["item-2", "item-0", "item-1"])
    }

    @Test func quotedBoundaryAndSniffedBoundary() throws {
        let body = "--xyz\r\n\(part("item-0"))\r\n--xyz--\r\n"
        #expect(BatchCodec.parse(contentType: "multipart/mixed; boundary=\"xyz\"", body: data(body))?.count == 1)
        #expect(BatchCodec.parse(contentType: "multipart/mixed", body: data(body))?.count == 1)
        #expect(BatchCodec.parse(contentType: "application/json", body: data("{}")) == nil)
        #expect(BatchCodec.parse(contentType: nil, body: Data()) == nil)
    }

    @Test func bodiesWithBoundaryLikeTextAndBinaryBytesSurvive() throws {
        let json = "{\"snippet\":\"--b1 not a delimiter\",\"x\":\"caf\u{e9}\"}"
        let body = "--b1\r\n\(part("item-0", json: json))\r\n--b1--\r\n"
        let parts = try #require(BatchCodec.parse(contentType: "multipart/mixed; boundary=b1", body: data(body)))
        #expect(String(decoding: parts[0].body, as: UTF8.self) == json)
    }

    @Test func contentIDNormalization() {
        #expect(BatchCodec.normalize("<response-item-12>") == "item-12")
        #expect(BatchCodec.normalize("<item-3>") == "item-3")
        #expect(BatchCodec.normalize(" item-4 ") == "item-4")
    }
}
