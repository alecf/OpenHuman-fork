import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct DenyListTransportTests {
    private static let api = GmailRequests.api
    private static let upload = GmailRequests.upload

    private static let denied: [(String, String, String)] = [
        ("DELETE", api + "messages/m1", "permanent delete"),
        ("DELETE", api + "threads/t1", "permanent delete"),
        ("POST", api + "messages/batchDelete", "permanent delete"),
        ("POST", api + "threads/t1/delete", "permanent delete"),
        ("DELETE", api + "labels/Label_1", "label"),
        ("PUT", api + "labels/Label_1", "label"),
        ("PATCH", api + "labels/Label_1", "label"),
        ("POST", api + "trash/empty", "trash"),
        ("DELETE", api + "trash", "trash"),
        ("POST", api + "spam/emptySpam", "trash or spam"),
        ("POST", api + "messages/emptyTrash", "trash or spam"),
        ("POST", api + "settings/filters", "settings"),
        ("DELETE", api + "settings/filters/f1", "permanent delete"),
        ("POST", api + "settings/forwardingAddresses", "settings"),
        ("PUT", api + "settings/autoForwarding", "settings"),
        ("POST", api + "settings/delegates", "settings"),
        ("POST", api + "settings/sendAs", "settings"),
        ("PUT", api + "settings/sendAs/alias%40example.com", "settings"),
        ("PATCH", api + "settings/sendAs/alias@example.com", "settings"),
        ("POST", api + "settings/sendAs/alias@example.com/verify", "settings"),
        ("PUT", api + "settings/vacation", "settings"),
        ("PUT", api + "settings/imap", "settings"),
        ("PUT", api + "settings/pop", "settings"),
        ("PUT", api + "settings/language", "settings"),
        ("POST", api + "settings/cse/identities", "settings"),
        ("POST", upload + "messages/import?uploadType=multipart", "import"),
        ("POST", api + "watch", "push"),
        ("POST", api + "stop", "push"),
        ("HEAD", api + "messages/m1", "method"),
        ("PATCH", other + "labels/L1", "label"),
        ("PUT", other + "labels/L1", "label"),
        ("DELETE", other + "messages/m1", "permanent delete"),
        ("POST", other + "messages/batchDelete", "permanent delete"),
        ("POST", other + "watch", "push"),
        ("POST", other + "settings/filters", "settings"),
        ("POST", other + "trash/empty", "trash"),
        ("POST", otherUpload + "messages/import?uploadType=multipart", "import"),
        ("PATCH", "https://gmail.googleapis.com/gmail/v1/users/robin@example.com/labels/L1", "label"),
        // Dot segments are refused raw or percent-encoded, whatever they would resolve to
        ("PATCH", api + "messages/x/../../labels/L1", "segment"),
        ("POST", api + "messages/m1/../m2/modify", "segment"),
        ("POST", api + "messages/x/%2E%2E/%2e%2e/labels/L1", "segment"),
        ("POST", api + "./messages/m1/modify", "segment"),
        ("GET", api + "messages/../../users/other/messages/m1", "segment"),
        ("POST", "https://evil.example.com/gmail/v1/users/me/messages/m1/modify", "gmail.googleapis.com"),
        ("GET", "https://evil.example.com/gmail/v1/users/me/messages/m1", "gmail.googleapis.com"),
        ("POST", "http://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify", "gmail.googleapis.com"),
        ("POST", "https://gmail.googleapis.com:8443/gmail/v1/users/me/messages/m1/modify", "gmail.googleapis.com"),
        ("POST", "https://user@gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify", "gmail.googleapis.com"),
        ("POST", "https://evil.example.com/batch/gmail/v1", "gmail.googleapis.com"),
        ("PUT", "https://gmail.googleapis.com/batch/gmail/v1", "resource"),
        ("PATCH", "https://gmail.googleapis.com/batch/gmail/v1", "resource"),
        ("POST", "https://gmail.googleapis.com/gmail/v1/messages/m1/modify", "resource"),
        ("POST", "https://gmail.googleapis.com/gmail/v2/users/me/messages/m1/modify", "resource"),
        ("POST", "https://gmail.googleapis.com/", "resource"),
        ("PATCH", "https://gmail.googleapis.com/gmail/v1/users//labels/L1", "resource"),
        ("POST", api + "messages//m1/modify", "resource"),
    ]

    private static let other = "https://gmail.googleapis.com/gmail/v1/users/someone%40example.com/"
    private static let otherUpload = "https://gmail.googleapis.com/upload/gmail/v1/users/someone%40example.com/"

    @Test func everyDenyListedEndpointIsRefusedBeforeTheWire() async {
        for (method, url, word) in Self.denied {
            let inner = ScriptedTransport()
            let transport = DenyListTransport(wrapping: inner, recipients: SendRecipientGate())
            let request = GmailRequests.request(method, url, body: method == "GET" ? nil : Data("{}".utf8))
            let reason = DenyListTransport.refusalReason(for: request)
            #expect(reason?.contains(word) == true, "\(method) \(url): \(reason ?? "passed")")
            let path = request.url.path(percentEncoded: true)
            await #expect(throws: TransportError.refusedByGuard("\(method) \(path)"), "\(method) \(url)") {
                _ = try await transport.send(request)
            }
            #expect(inner.requests.isEmpty, "\(method) \(url) reached the wire")
        }
    }

    @Test func methodOverridesAndWriteBatchesAreRefused() async {
        let overrides = [
            GmailRequests.request("POST", Self.api + "messages/m1/modify", body: Data("{}".utf8),
                       extraHeaders: ["X-HTTP-Method-Override": "DELETE"]),
            GmailRequests.request("POST", Self.api + "messages/m1/modify?$httpMethod=DELETE", body: Data("{}".utf8)),
        ]
        let boundary = "batch_ab12"
        let writeBatch = GmailRequests.request("POST", "https://gmail.googleapis.com/batch/gmail/v1", body: Data("""
            --\(boundary)\r
            Content-Type: application/http\r
            \r
            DELETE /gmail/v1/users/me/messages/m1\r
            \r
            --\(boundary)--\r

            """.utf8), extraHeaders: ["Content-Type": "multipart/mixed; boundary=\(boundary)"])
        for request in overrides + [writeBatch] {
            let inner = ScriptedTransport()
            #expect(DenyListTransport.refusalReason(for: request) != nil, "\(request.url)")
            await #expect(throws: TransportError.self) { _ = try await DenyListTransport(wrapping: inner).send(request) }
            #expect(inner.requests.isEmpty)
        }
        let readBatch = GmailRequests.request("POST", "https://gmail.googleapis.com/batch/gmail/v1", body: Data("""
            --\(boundary)\r
            Content-Type: application/http\r
            \r
            GET /gmail/v1/users/me/threads/t1?format=metadata\r
            \r
            --\(boundary)--\r

            """.utf8), extraHeaders: ["Content-Type": "multipart/mixed; boundary=\(boundary)"])
        #expect(DenyListTransport.refusalReason(for: readBatch) == nil)
    }

    @Test func theAppsOwnWritesPass() async throws {
        let message = GmailRequests.message(["From: me@example.com", "To: dana@example.org", "Subject: Synthetic"])
        let draftMeta = #"{"message":{}}"#
        let allowed: [HTTPRequest] = [
            GmailRequests.request("GET", Self.api + "threads/t1?format=metadata"),
            GmailRequests.request("GET", Self.api + "settings/sendAs"),
            GmailRequests.json("POST", Self.api + "messages/batchModify", ["ids": ["m1"], "removeLabelIds": ["INBOX"]]),
            GmailRequests.json("POST", Self.api + "messages/m1/modify", ["addLabelIds": ["STARRED"]]),
            GmailRequests.json("POST", Self.api + "threads/t1/modify", ["addLabelIds": ["STARRED"]]),
            GmailRequests.request("POST", Self.api + "messages/m1/trash"),
            GmailRequests.request("POST", Self.api + "threads/t1/trash"),
            GmailRequests.request("POST", Self.api + "threads/t1/untrash"),
            GmailRequests.json("POST", Self.api + "labels", ["name": "OpenHuman/Snoozed/20261012T0900Z"]),
            GmailRequests.upload("POST", Self.upload + "drafts?uploadType=multipart", metadata: draftMeta, message: message),
            GmailRequests.upload("PUT", Self.upload + "drafts/d1?uploadType=multipart", metadata: #"{"id":"d1","message":{}}"#,
                      message: message),
            GmailRequests.request("DELETE", Self.api + "drafts/d1"),
            GmailRequests.json("POST", Self.api + "drafts/send", ["id": "d1"]),
            GmailRequests.upload("POST", Self.upload + "messages/send?uploadType=multipart", metadata: "{}", message: message),
        ]
        for request in allowed {
            let inner = ScriptedTransport { _ in GmailRequests.genericResponse }
            #expect(DenyListTransport.refusalReason(for: request) == nil, "\(request.method) \(request.url)")
            _ = try await DenyListTransport(wrapping: inner, recipients: SendRecipientGate()).send(request)
            #expect(inner.requests == [request], "\(request.method) \(request.url) is forwarded unchanged")
        }
    }

    private static func addresses(_ n: Int, domain: String = "example.org") -> [String] {
        (1...n).map { "person\($0)@\(domain)" }
    }

    private static func raw(to: [String], cc: [String] = [], bcc: [String] = []) -> Data {
        var lines = ["From: me@example.com", "To: " + to.joined(separator: ", ")]
        if !cc.isEmpty { lines.append("Cc: " + cc.joined(separator: ",\r\n ")) }
        if !bcc.isEmpty { lines.append("Bcc: " + bcc.joined(separator: ", ")) }
        lines.append("Subject: Synthetic")
        return GmailRequests.message(lines)
    }

    @Test func aSendOverTheLimitNeedsTheUsersConfirmation() async throws {
        let gate = SendRecipientGate(limit: 3)
        let inner = ScriptedTransport { _ in jsonResponse(200, ["id": "d1", "message": ["id": "m1", "threadId": "t1"]]) }
        let transport = DenyListTransport(wrapping: inner, recipients: gate)
        let four = Self.addresses(4)
        func send(_ raw: Data) -> HTTPRequest {
            GmailRequests.upload("POST", Self.upload + "messages/send?uploadType=multipart", metadata: "{}", message: raw)
        }

        _ = try await transport.send(send(Self.raw(to: Array(four.prefix(2)), cc: [four[2]])))
        let over = send(Self.raw(to: [four[0]], cc: [four[1], four[2]], bcc: [four[3]]))
        await #expect(throws: TransportError.refusedByGuard("POST /upload/gmail/v1/users/me/messages/send")) {
            _ = try await transport.send(over)
        }
        #expect(gate.refusalReason(for: over)?.contains("4 recipients is over the limit of 3") == true)
        gate.confirm(four.map { $0.uppercased() })
        _ = try await transport.send(over)
        #expect(inner.requests.count == 2)
        let other = send(Self.raw(to: Self.addresses(4, domain: "example.net")))
        await #expect(throws: TransportError.self) { _ = try await transport.send(other) }
        let unreadable = GmailRequests.request("POST", Self.upload + "messages/send", body: Data("not an upload".utf8))
        await #expect(throws: TransportError.self) { _ = try await transport.send(unreadable) }

        let five = Self.addresses(5)
        let created = GmailRequests.upload("POST", Self.upload + "drafts?uploadType=multipart", metadata: #"{"message":{}}"#,
                                message: Self.raw(to: five))
        _ = try await transport.send(created)
        #expect(gate.recipients(ofDraft: "d1") == .some(.some(five)))
        let sendDraft = GmailRequests.json("POST", Self.api + "drafts/send", ["id": "d1"])
        await #expect(throws: TransportError.refusedByGuard("POST /gmail/v1/users/me/drafts/send")) {
            _ = try await transport.send(sendDraft)
        }
        gate.confirm(five)
        _ = try await transport.send(sendDraft)
        _ = try await transport.send(GmailRequests.json("POST", Self.api + "drafts/send", ["id": "d-from-another-launch"]))
        _ = try await DenyListTransport(wrapping: ScriptedTransport()).send(other)
    }

    @Test func recipientsAreReadLikeAMailReaderWouldCountThem() {
        let field = #""Ruiz, Dana" <Dana@Example.org>, sam@example.org (Sam, at work), team: a@example.org, b@example.org;, "#
            + "not-an-address, <c@example.org>"
        #expect(OutgoingRecipients.addresses(inField: field)
            == ["dana@example.org", "sam@example.org", "a@example.org", "b@example.org", "c@example.org"])
        let raw = Self.raw(to: ["x@example.org"], cc: ["y@example.org", "z@example.org"], bcc: ["w@example.org"])
        #expect(OutgoingRecipients.addresses(inRFC822: raw)?.sorted()
            == ["w@example.org", "x@example.org", "y@example.org", "z@example.org"])
        #expect(OutgoingRecipients.addresses(inRFC822: Data("no header block".utf8)) == nil)
        #expect(SendRecipientGate.normalized([" A@b.c", "a@B.C", ""]) == ["a@b.c"])
        #expect(SendRecipientGate(limit: 0).limit == 1)
    }

    @Test func theClientStackReachesFakeGmail() async throws {
        let clock = InstantClock()
        let gmail = FakeGmail(clock: clock)
        let wire = FakeGmailWire(gmail)
        let gate = SendRecipientGate(limit: 20)
        let transport = DenyListTransport(wrapping: wire, recipients: gate)
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: transport,
                                 config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                                 jitter: { 0 })
        let threads = await gmail.seedInbox(count: 3)
        try await client.batchModifyMessages(ids: [threads[0]], add: ["STARRED"], remove: ["INBOX"])
        _ = try await client.trashThread(id: threads[1])
        _ = try await client.untrashThread(id: threads[1])
        let draft = try await client.createDraft(rawRFC822: Self.raw(to: ["dana@example.org"]), threadID: nil)
        #expect(gate.recipients(ofDraft: draft.id) == .some(.some(["dana@example.org"])))
        _ = try await client.sendDraft(id: draft.id)
        #expect(wire.nonGETRequests.count == 5)
        do {
            _ = try await transport.send(GmailRequests.request("DELETE", Self.api + "messages/\(threads[2])"))
            Issue.record("a permanent delete passed")
        } catch TransportError.refusedByGuard {}
        #expect(wire.nonGETRequests.count == 5, "the forged delete never reached the fake")
    }
}
