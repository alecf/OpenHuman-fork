import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct ReadOnlyTransportTests {
    private static let api = "https://gmail.googleapis.com/gmail/v1/users/me/"
    private static let upload = "https://gmail.googleapis.com/upload/gmail/v1/users/me/"

    private func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: url)!, headers: headers, body: body)
    }

    private func expectRefused(_ request: HTTPRequest, payload expected: String? = nil,
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        let inner = ScriptedTransport()
        let guarded = ReadOnlyTransport(wrapping: inner)
        let payload = expected ?? "\(request.method) \(request.url.path(percentEncoded: true))"
        await #expect(throws: TransportError.blockedBySafeMode(payload), sourceLocation: sourceLocation) {
            _ = try await guarded.send(request)
        }
        #expect(inner.requests.isEmpty, "a refused request reached the wrapped transport", sourceLocation: sourceLocation)
    }

    @Test func everyReadPathPasses() async throws {
        let inner = ScriptedTransport()
        let guarded = ReadOnlyTransport(wrapping: inner)
        let reads = [
            "profile", "settings/sendAs", "labels", "labels/INBOX",
            "threads?labelIds=INBOX&maxResults=50", "threads/t1?format=metadata&metadataHeaders=From&metadataHeaders=To",
            "messages?q=in%3Ainbox", "messages/m1?format=full", "messages/m1?format=raw", "messages/m1/attachments/a1",
            "history?startHistoryId=1&historyTypes=messageAdded&maxResults=500", "drafts", "drafts/d1?format=full",
        ]
        for path in reads {
            let response = try await guarded.send(request("GET", Self.api + path, headers: ["Authorization": "Bearer x"]))
            #expect(response.status == 200)
        }
        #expect(inner.requests.count == reads.count)
        #expect(inner.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func everyWriteIsRefused() async {
        let writes: [(String, String)] = [
            ("POST", Self.api + "messages/send"),
            ("POST", Self.upload + "messages/send?uploadType=multipart"),
            ("POST", Self.api + "drafts/send"),
            ("POST", Self.api + "messages/m1/modify"),
            ("POST", Self.api + "messages/batchModify"),
            ("POST", Self.api + "messages/m1/trash"),
            ("POST", Self.api + "messages/m1/untrash"),
            ("POST", Self.api + "threads/t1/modify"),
            ("POST", Self.api + "threads/t1/trash"),
            ("POST", Self.api + "threads/t1/untrash"),
            ("POST", Self.upload + "messages?uploadType=multipart&internalDateSource=receivedTime"),
            ("POST", Self.api + "messages/import"),
            ("POST", Self.api + "labels"),
            ("PUT", Self.api + "labels/Label_1"),
            ("PATCH", Self.api + "labels/Label_1"),
            ("DELETE", Self.api + "labels/Label_1"),
            ("POST", Self.api + "drafts"),
            ("POST", Self.upload + "drafts?uploadType=multipart"),
            ("PUT", Self.api + "drafts/d1"),
            ("PUT", Self.upload + "drafts/d1?uploadType=multipart"),
            ("DELETE", Self.api + "drafts/d1"),
            ("DELETE", Self.api + "messages/m1"),
            ("DELETE", Self.api + "threads/t1"),
            ("POST", Self.api + "messages/batchDelete"),
            ("POST", Self.api + "settings/filters"),
            ("POST", Self.api + "settings/forwardingAddresses"),
            ("PUT", Self.api + "settings/vacation"),
            ("PATCH", Self.api + "settings/sendAs/me%40example.com"),
            ("POST", Self.api + "stop"),
            ("POST", Self.api + "watch"),
            ("HEAD", Self.api + "profile"),
            ("OPTIONS", Self.api + "profile"),
            ("get", Self.api + "profile"),
            ("CONNECT", "https://gmail.googleapis.com:443/"),
        ]
        for (method, url) in writes {
            await expectRefused(request(method, url, body: Data("{}".utf8)))
        }
    }

    @Test func emptyMethodIsRefused() async {
        await expectRefused(request("", Self.api + "profile"), payload: " /gmail/v1/users/me/profile")
    }

    @Test func payloadIsMethodAndPathWithoutQueryOrBody() async {
        await expectRefused(request("POST", Self.api + "messages/m1/modify?alt=json&fields=id",
                                    body: Data(#"{"addLabelIds":["STARRED"]}"#.utf8)),
                            payload: "POST /gmail/v1/users/me/messages/m1/modify")
    }

    @Test func logLineRedactsAddressSegments() {
        #expect(ReadOnlyTransport.redactingAddresses("PATCH /gmail/v1/users/me/settings/sendAs/me%40example.com")
                == "PATCH /gmail/v1/users/me/settings/sendAs/<redacted>")
        #expect(ReadOnlyTransport.redactingAddresses("POST /gmail/v1/users/a@b.c/messages/send")
                == "POST /gmail/v1/users/<redacted>/messages/send")
        #expect(ReadOnlyTransport.redactingAddresses("POST /gmail/v1/users/me/labels") == "POST /gmail/v1/users/me/labels")
    }

    @Test func methodOverridesAndGETBodiesAreRefused() async {
        for header in ["X-HTTP-Method-Override", "x-http-method-override", "X-HTTP-Method", "X-Method-Override"] {
            await expectRefused(request("GET", Self.api + "messages/m1", headers: [header: "DELETE"]))
        }
        await expectRefused(request("GET", Self.api + "messages/m1?$httpMethod=DELETE"))
        await expectRefused(request("GET", Self.api + "messages/m1?_method=DELETE"))
        await expectRefused(request("GET", Self.api + "messages/m1", body: Data("x".utf8)))
    }

    private static let boundary = "batch_synthetic_0123"

    private func batch(_ parts: [String], boundary: String = boundary, newline: String = "\r\n",
                       contentType: String? = nil, preamble: String = "", epilogue: String = "",
                       close: Bool = true) -> HTTPRequest {
        var body = preamble
        for part in parts { body += "--\(boundary)\(newline)\(part.replacingOccurrences(of: "\n", with: newline))\(newline)" }
        if close { body += "--\(boundary)--\(newline)" }
        body += epilogue
        return request("POST", "https://gmail.googleapis.com/batch/gmail/v1",
                       headers: ["Content-Type": contentType ?? "multipart/mixed; boundary=\(boundary)",
                                 "Authorization": "Bearer x"],
                       body: Data(body.utf8))
    }

    private func part(_ requestLine: String, partHeaders: String = "Content-Type: application/http\nContent-ID: <item-1>",
                      innerHeaders: String = "", innerBody: String = "") -> String {
        var text = "\(partHeaders)\n\n\(requestLine)\n"
        if !innerHeaders.isEmpty { text += innerHeaders + "\n" }
        if !innerBody.isEmpty { text += "\n" + innerBody }
        return text
    }

    private let getLine = "GET /gmail/v1/users/me/messages/m1?format=metadata&metadataHeaders=From HTTP/1.1"

    @Test func allGETBatchPasses() async throws {
        for newline in ["\r\n", "\n"] {
            let inner = ScriptedTransport()
            let guarded = ReadOnlyTransport(wrapping: inner)
            let request = batch([part(getLine), part("GET /gmail/v1/users/me/threads/t2?format=minimal"),
                                 part(getLine, innerHeaders: "Accept: application/json")], newline: newline)
            _ = try await guarded.send(request)
            #expect(inner.requests.count == 1)
        }
        let inner = ScriptedTransport()
        _ = try await ReadOnlyTransport(wrapping: inner).send(
            batch([part(getLine)], contentType: "Multipart/Mixed; charset=utf-8; boundary=\"\(Self.boundary)\""))
        #expect(inner.requests.count == 1)
    }

    @Test func batchWithAnyNonGETInnerRequestIsRefusedWhole() async {
        let payload = "POST /batch/gmail/v1"
        let refused: [HTTPRequest] = [
            batch([part(getLine), part("POST /gmail/v1/users/me/messages/m1/modify HTTP/1.1")]),
            batch([part("DELETE /gmail/v1/users/me/drafts/d1 HTTP/1.1"), part(getLine)]),
            batch([part("POST /gmail/v1/users/me/messages/send HTTP/1.1",
                        innerHeaders: "Content-Type: application/json", innerBody: "{}")]),
            batch([part("get /gmail/v1/users/me/messages/m1 HTTP/1.1")]),
            batch([part("GET  /gmail/v1/users/me/messages/m1 HTTP/1.1")]),
            batch([part("GET https://gmail.googleapis.com/gmail/v1/users/me/messages/m1 HTTP/1.1")]),
            batch([part("GET /gmail/v1/users/me/messages/m1 HTTP/2 extra")]),
            batch([part(getLine, innerHeaders: "X-HTTP-Method-Override: POST")]),
            batch([part("GET /gmail/v1/users/me/messages/m1?$httpMethod=DELETE HTTP/1.1")]),
            batch([part(getLine, innerBody: "{\"addLabelIds\":[\"TRASH\"]}")]),
            batch([part(getLine, partHeaders: "Content-Type: multipart/mixed; boundary=nested")]),
            batch([part(getLine, partHeaders: "Content-ID: <item-1>")]),
            batch([part(getLine, partHeaders: "Content-Type: application/http\nContent-Transfer-Encoding: base64")]),
            batch([part(getLine, partHeaders: "Content-Type: application/http\n folded-continuation")]),
            batch([part(getLine)], contentType: "multipart/mixed"),
            batch([part(getLine)], contentType: "application/json"),
            batch([part(getLine)], close: false),
            batch([part(getLine)], preamble: "POST /gmail/v1/users/me/messages/send HTTP/1.1\r\n"),
            batch([part(getLine)], epilogue: "--\(Self.boundary)\r\n" + part("POST /x HTTP/1.1")),
            batch([]),
            batch(["Content-Type: application/http\n"]),
        ]
        for request in refused { await expectRefused(request, payload: payload) }
        await expectRefused(request("POST", "https://gmail.googleapis.com/batch/gmail/v1",
                                    headers: ["Content-Type": "multipart/mixed; boundary=b"]), payload: payload)
    }

    @Test func batchBoundaryParsing() {
        #expect(BatchInspector.boundary(fromContentType: "multipart/mixed; boundary=abc") == "abc")
        #expect(BatchInspector.boundary(fromContentType: "multipart/mixed;boundary=\"a b\"") == "a b")
        #expect(BatchInspector.boundary(fromContentType: "multipart/related; boundary=abc") == nil)
        #expect(BatchInspector.boundary(fromContentType: "multipart/mixed; boundary=") == nil)
        #expect(BatchInspector.boundary(fromContentType: "multipart/mixed; boundary=" + String(repeating: "x", count: 71)) == nil)
    }
}
