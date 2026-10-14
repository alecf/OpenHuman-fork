import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct EndpointFixtureTests {
    private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/http/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    private static func ok(_ name: String) -> HTTPResponse { HTTPResponse(status: 200, headers: [:], body: fixture(name)) }

    private func client(_ http: any HTTPTransport) -> GmailClient {
        let clock = InstantClock()
        return GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: http,
                           config: GmailClientConfig(userAgent: "t"), clock: clock, metrics: nil,
                           limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                           jitter: { 0 })
    }

    private func query(_ r: HTTPRequest) -> [String] {
        (URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
    }

    @Test func fixturesExist() {
        for name in ["profile", "sendAs.list", "labels.list", "label.get", "threads.list", "messages.list", "thread.get.full",
                     "drafts.list", "draft.get", "history.list", "message.modify"] {
            #expect(!Self.fixture(name).isEmpty, "\(name)")
        }
    }

    @Test func profileLabelsAndSendAs() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/profile") { _ in Self.ok("profile") }
        http.on("GET", "/gmail/v1/users/me/settings/sendAs") { _ in Self.ok("sendAs.list") }
        http.on("GET", "/gmail/v1/users/me/labels") { _ in Self.ok("labels.list") }
        http.on("GET", "/gmail/v1/users/me/labels/Label_7") { _ in Self.ok("label.get") }
        let c = client(http)
        let profile = try await c.getProfile(priority: .interactive)
        #expect(profile.emailAddress == "me@example.com" && profile.historyId == "4242" && profile.messagesTotal == 1200)
        let sendAs = try await c.listSendAs()
        #expect(sendAs.map(\.sendAsEmail) == ["me@example.com", "alias@example.com"] && sendAs[0].isPrimary == true)
        #expect(sendAs[0].signature == "<div>Me Example<br>Example Co.</div>" && sendAs[1].signature == nil)
        #expect(sendAs.map(\.verificationStatus) == ["accepted", "pending"])
        let labels = try await c.listLabels()
        #expect(labels.count == 2 && labels[1].color?.backgroundColor == "#16a766" && labels[0].type == "system")
        let label = try await c.getLabel(id: "Label_7")
        #expect(label.messagesUnread == 2 && label.threadsTotal == 6)
        let r = http.requests
        #expect(r.map(\.method) == ["GET", "GET", "GET", "GET"])
        #expect(query(r[0]).isEmpty)
        #expect(query(r[1])
            == ["fields=sendAs(sendAsEmail,displayName,replyToAddress,signature,isPrimary,isDefault,verificationStatus)"])
        #expect(r[3].url.path() == "/gmail/v1/users/me/labels/Label_7")
    }

    @Test func threadAndMessageListsSelectFields() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/threads") { _ in Self.ok("threads.list") }
        http.on("GET", "/gmail/v1/users/me/messages") { _ in Self.ok("messages.list") }
        let c = client(http)
        let threads = try await c.listThreads(ListQuery(labelIDs: ["INBOX"], q: "before:1 a+b", maxResults: 500), priority: .sync)
        #expect(threads.threads?.map(\.id) == ["t1", "t2"] && threads.nextPageToken == "page2" && threads.resultSizeEstimate == 201)
        let messages = try await c.listMessages(ListQuery(maxResults: 9999, includeSpamTrash: true), priority: .sync)
        #expect(messages.messages?.map(\.id) == ["m1", "m2"] && messages.messages?.first?.threadId == "t1")
        let r = http.requests
        #expect(query(r[0]) == ["labelIds=INBOX", "q=before:1 a+b", "maxResults=500",
                                "fields=threads(id,snippet,historyId),nextPageToken,resultSizeEstimate"])
        #expect(r[0].url.query(percentEncoded: true)?.contains("q=before%3A1%20a%2Bb") == true)
        #expect(query(r[1]) == ["maxResults=500", "includeSpamTrash=true",
                                "fields=messages(id,threadId),nextPageToken,resultSizeEstimate"])
    }

    @Test func getThreadFullDecodesPartsAndAttachment() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/threads/t1") { _ in Self.ok("thread.get.full") }
        let thread = try await client(http).getThread(id: "t1", format: .full, metadataHeaders: ["Subject"], priority: .interactive)
        let message = try #require(thread.messages?.first)
        #expect(message.labelIds == ["INBOX", "UNREAD"] && message.internalDateValue != nil && message.historyIDValue == HistoryID(100))
        let parts = try #require(message.payload?.parts)
        #expect(parts.count == 2 && parts[0].parts?.count == 2 && parts[1].body?.attachmentId == "ANGjdJ_att")
        #expect(query(http.requests[0]) == ["format=full"], "metadataHeaders only go with format=metadata")
    }

    @Test func historyDecodesAllFourRecordKinds() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/history") { _ in Self.ok("history.list") }
        let page = try await client(http).listHistory(startHistoryID: HistoryID(200), pageToken: nil, types: [.labelAdded],
                                                      labelID: "INBOX", maxResults: 9999, priority: .sync)
        let h = try #require(page.history)
        #expect(h.count == 4 && h[0].messagesAdded?.first?.message.id == "m1" && h[1].messagesDeleted?.first?.message.id == "m2")
        #expect(h[2].labelsAdded?.first?.labelIds == ["STARRED"] && h[3].labelsRemoved?.first?.labelIds == ["UNREAD"])
        #expect(page.nextPageToken == "page2" && page.historyId == "250")
        #expect(query(http.requests[0]) == ["startHistoryId=200", "maxResults=500", "historyTypes=labelAdded", "labelId=INBOX"])
    }

    @Test func draftsListAndGet() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/drafts") { _ in Self.ok("drafts.list") }
        http.on("GET", "/gmail/v1/users/me/drafts/r1") { _ in Self.ok("draft.get") }
        let c = client(http)
        let list = try await c.listDrafts(pageToken: "tok", q: "subject:x", maxResults: 0)
        #expect(list.drafts?.first?.message?.threadId == "t9" && list.nextPageToken == "page2")
        let draft = try await c.getDraft(id: "r1", format: .full)
        #expect(draft.message?.labelIds == ["DRAFT"])
        #expect(query(http.requests[0]) == ["maxResults=1", "pageToken=tok", "q=subject:x",
                                            "fields=drafts(id,message(id,threadId)),nextPageToken,resultSizeEstimate"])
        #expect(query(http.requests[1]) == ["format=full"])
    }

    @Test func writeRequestShapes() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", "/gmail/v1/users/me") { _ in Self.ok("message.modify") }
        http.on("POST", "/gmail/v1/users/me/threads") { _ in HTTPResponse(status: 200, headers: [:], body: Data(#"{"id":"t1"}"#.utf8)) }
        http.on("POST", "/gmail/v1/users/me/labels") { _ in Self.ok("label.get") }
        http.on("POST", "/gmail/v1/users/me/drafts/send") { _ in Self.ok("message.modify") }
        http.on("DELETE", "/gmail/v1/users/me/drafts/") { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        let c = client(http)
        let modified = try await c.modifyMessage(id: "m1", add: ["STARRED"], remove: ["UNREAD"])
        #expect(modified.labelIds == ["INBOX", "STARRED"])
        _ = try await c.trashMessage(id: "m1")
        _ = try await c.untrashMessage(id: "m1")
        _ = try await c.trashThread(id: "t1")
        _ = try await c.untrashThread(id: "t1")
        _ = try await c.createLabel(name: "Projects/Alpha", labelListVisibility: "labelShow", messageListVisibility: nil)
        _ = try await c.sendDraft(id: "r1")
        try await c.deleteDraft(id: "r1")
        let r = http.requests
        let shape = r.map { "\($0.method) \($0.url.path())" }
        #expect(shape == ["POST /gmail/v1/users/me/messages/m1/modify", "POST /gmail/v1/users/me/messages/m1/trash",
                          "POST /gmail/v1/users/me/messages/m1/untrash", "POST /gmail/v1/users/me/threads/t1/trash",
                          "POST /gmail/v1/users/me/threads/t1/untrash", "POST /gmail/v1/users/me/labels",
                          "POST /gmail/v1/users/me/drafts/send", "DELETE /gmail/v1/users/me/drafts/r1"])
        let modifyBody = try JSONSerialization.jsonObject(with: r[0].body ?? Data()) as? [String: [String]]
        #expect(modifyBody == ["addLabelIds": ["STARRED"], "removeLabelIds": ["UNREAD"]])
        #expect(r[1].body == nil && r[1].headers["Content-Type"] == nil)
        #expect(String(decoding: r[5].body ?? Data(), as: UTF8.self).contains("\"name\":\"Projects\\/Alpha\""))
        #expect(String(decoding: r[6].body ?? Data(), as: UTF8.self) == #"{"id":"r1"}"#)
        #expect(r[7].body == nil)
    }

    @Test func updateDraftAndSendBuildMultipartUploads() async throws {
        let http = FakeHTTPTransport()
        http.on("PUT", "/upload/gmail/v1/users/me/drafts/") { _ in Self.ok("draft.get") }
        http.on("POST", "/upload/gmail/v1/users/me/messages/send") { _ in Self.ok("message.modify") }
        let c = client(http)
        let mime = Data("To: a@example.com\r\nBcc: hidden@example.com\r\nSubject: s\r\n\r\nbody".utf8)
        _ = try await c.updateDraft(id: "r1", rawRFC822: mime, threadID: "t1")
        _ = try await c.sendMessage(rawRFC822: mime, threadID: "t1")
        let r = http.requests
        #expect(r[0].method == "PUT" && r[0].url.path() == "/upload/gmail/v1/users/me/drafts/r1" && query(r[0]) == ["uploadType=multipart"])
        #expect(r[1].url.path() == "/upload/gmail/v1/users/me/messages/send" && query(r[1]) == ["uploadType=multipart"])
        let body0 = String(decoding: r[0].body ?? Data(), as: UTF8.self)
        #expect(body0.contains(#"{"id":"r1","message":{"threadId":"t1"}}"#) && body0.contains("Bcc: hidden@example.com"))
        #expect(String(decoding: r[1].body ?? Data(), as: UTF8.self).contains(#"{"threadId":"t1"}"#))
        let boundary = try #require(r[1].headers["Content-Type"]?.components(separatedBy: "boundary=").last)
        let bodyData = try #require(r[1].body)
        #expect(String(decoding: bodyData, as: UTF8.self).hasSuffix("--\(boundary)--\r\n"))
        #expect(bodyData.range(of: mime) != nil)
    }

    @Test func uploadsOverTheLimitFailBeforeAnyRequest() async throws {
        let http = FakeHTTPTransport()
        let c = client(http)
        let big = Data(count: 35 * 1024 * 1024 + 1)
        await #expect(throws: GmailError.payloadTooLarge) { _ = try await c.sendMessage(rawRFC822: big, threadID: nil) }
        await #expect(throws: GmailError.payloadTooLarge) { _ = try await c.createDraft(rawRFC822: big, threadID: nil) }
        #expect(http.requests.isEmpty)
    }

    @Test func batchModifyChunksAtOneThousandIDsAndSkipsEmptyInput() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", "/gmail/v1/users/me/messages/batchModify") { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        let c = client(http)
        try await c.batchModifyMessages(ids: [], add: ["A"], remove: [])
        #expect(http.requests.isEmpty)
        let ids = (0..<2500).map { "m\($0)" }
        try await c.batchModifyMessages(ids: ids, add: [], remove: ["UNREAD"])
        let sizes = try http.requests.map { r in
            try #require((JSONSerialization.jsonObject(with: r.body ?? Data()) as? [String: Any])?["ids"] as? [String]).count
        }
        #expect(sizes == [1000, 1000, 500])
    }

    @Test func largeAttachmentRoundTripsAndChecksSize() async throws {
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/messages/m1/attachments/a1") { _ in
            FakeHTTPTransport.json(200, ["size": payload.count, "data": Base64URL.encode(payload)])
        }
        http.on("GET", "/gmail/v1/users/me/messages/m1/attachments/empty") { _ in FakeHTTPTransport.json(200, ["size": 0]) }
        http.on("GET", "/gmail/v1/users/me/messages/m1/attachments/liar") { _ in
            FakeHTTPTransport.json(200, ["size": 99, "data": Base64URL.encode(Data("abc".utf8))])
        }
        http.on("GET", "/gmail/v1/users/me/messages/m1/attachments/bad") { _ in FakeHTTPTransport.json(200, ["size": 3, "data": "***"]) }
        let c = client(http)
        #expect(try await c.getAttachment(messageID: "m1", attachmentID: "a1") == payload)
        #expect(try await c.getAttachment(messageID: "m1", attachmentID: "empty") == Data())
        await #expect(throws: GmailError.decoding("attachment size mismatch")) { _ = try await c.getAttachment(messageID: "m1", attachmentID: "liar") }
        await #expect(throws: GmailError.decoding("attachment data is not base64url")) { _ = try await c.getAttachment(messageID: "m1", attachmentID: "bad") }
        #expect(query(http.requests[0]) == ["fields=size,data"])
    }

    @Test func errorBodiesMapToContractErrors() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/labels") { _ in HTTPResponse(status: 403, headers: [:], body: Self.fixture("error.insufficientPermissions")) }
        http.on("GET", "/gmail/v1/users/me/profile") { _ in HTTPResponse(status: 400, headers: [:], body: Self.fixture("error.invalidLabel")) }
        http.on("POST", "/gmail/v1/users/me/labels") { _ in FakeHTTPTransport.json(409, ["error": ["code": 409, "message": "Label name exists or conflicts"]]) }
        http.on("POST", "/gmail/v1/users/me/messages/m1/modify") { _ in
            FakeHTTPTransport.json(400, ["error": ["code": 400, "message": "Invalid label: NOPE", "errors": [["reason": "invalidArgument"]]]])
        }
        http.on("GET", "/gmail/v1/users/me/messages/m1") { _ in FakeHTTPTransport.json(404, ["error": ["code": 404, "message": "Requested entity was not found."]]) }
        http.on("POST", "/upload/gmail/v1/users/me/messages/send") { _ in FakeHTTPTransport.json(413, ["error": ["code": 413, "message": "too big"]]) }
        let c = client(http)
        await #expect(throws: GmailError.forbidden(reason: "insufficientPermissions", message: "Request had insufficient authentication scopes.")) {
            _ = try await c.listLabels()
        }
        await #expect(throws: GmailError.badRequest(reason: "invalidArgument", message: "Invalid label: NOPE")) {
            _ = try await c.getProfile(priority: .sync)
        }
        await #expect(throws: GmailError.badRequest(reason: "conflict", message: "Label name exists or conflicts")) {
            _ = try await c.createLabel(name: "x", labelListVisibility: nil, messageListVisibility: nil)
        }
        await #expect(throws: GmailError.badRequest(reason: "invalidArgument", message: "Invalid label: NOPE")) {
            _ = try await c.modifyMessage(id: "m1", add: ["NOPE"], remove: [])
        }
        await #expect(throws: GmailError.notFound("messages/m1")) {
            _ = try await c.getMessage(id: "m1", format: .minimal, metadataHeaders: [], priority: .sync)
        }
        await #expect(throws: GmailError.payloadTooLarge) { _ = try await c.sendMessage(rawRFC822: Data("x".utf8), threadID: nil) }
    }

    @Test func paginationHelpersWalkEveryPageAndStopOnARepeatedToken() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/threads") { request in
            let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
            switch token {
            case nil: return FakeHTTPTransport.json(200, ["threads": [["id": "t1"]], "nextPageToken": "p2"])
            case "p2": return FakeHTTPTransport.json(200, ["threads": [["id": "t2"]], "nextPageToken": "p3"])
            default: return FakeHTTPTransport.json(200, ["threads": [["id": "t3"]], "nextPageToken": "p3"])
            }
        }
        http.on("GET", "/gmail/v1/users/me/history") { request in
            let token = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
            return token == nil
                ? FakeHTTPTransport.json(200, ["history": [["id": "1"]], "nextPageToken": "h2", "historyId": "10"])
                : FakeHTTPTransport.json(200, ["history": [["id": "2"]], "historyId": "11"])
        }
        let c = client(http)
        let all = try await c.allThreadStubs(ListQuery(), priority: .sync)
        #expect(all.map(\.id) == ["t1", "t2", "t3"])
        #expect(try await c.allThreadStubs(ListQuery(), priority: .sync, maxPages: 2).map(\.id) == ["t1", "t2"])
        let history = try await c.allHistory(startHistoryID: HistoryID(5), priority: .sync)
        #expect(history.records.map(\.id) == ["1", "2"] && history.historyId == "11")
    }
}
