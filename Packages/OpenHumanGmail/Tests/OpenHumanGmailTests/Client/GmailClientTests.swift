import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct GmailClientTests {
    private func client(_ http: any HTTPTransport, concurrency: Int = 8, batchSize: Int = 25) -> GmailClient {
        let clock = InstantClock()
        return GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: http,
                           config: GmailClientConfig(batchSize: batchSize, maxConcurrentRequests: concurrency, userAgent: "t"), clock: clock,
                           metrics: nil, limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: concurrency,
                                                               clock: clock),
                           jitter: { 0 })
    }

    private func query(_ r: HTTPRequest) -> [String] {
        (URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }
    }

    @Test func readRequestShapes() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/threads") { _ in FakeHTTPTransport.json(200, ["threads": [["id": "t1", "historyId": "9"]]]) }
        http.on("GET", "/gmail/v1/users/me/threads/t1") { _ in FakeHTTPTransport.json(200, ["id": "t1", "messages": [["id": "m1"]]]) }
        http.on("GET", "/gmail/v1/users/me/history") { _ in FakeHTTPTransport.json(200, ["historyId": "12"]) }
        let c = client(http)
        let list = try await c.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 50), priority: .interactive)
        #expect(list.threads?.first?.id == "t1" && list.threads?.first?.historyId == "9")
        _ = try await c.getThread(id: "t1", format: .metadata, metadataHeaders: ["From", "Subject"], priority: .interactive)
        _ = try await c.listHistory(startHistoryID: HistoryID(1000), pageToken: "pt", types: [], labelID: nil,
                                    maxResults: 500, priority: .sync)
        let r = http.requests
        #expect(r.allSatisfy { $0.method == "GET" && $0.url.host() == "gmail.googleapis.com" })
        #expect(r[0].url.path() == "/gmail/v1/users/me/threads" && query(r[0]) == ["labelIds=INBOX", "maxResults=50",
                                                                                      "fields=threads(id,snippet,historyId),nextPageToken,resultSizeEstimate"])
        #expect(r[1].url.path() == "/gmail/v1/users/me/threads/t1")
        #expect(query(r[1]) == ["format=metadata", "metadataHeaders=From", "metadataHeaders=Subject"])
        #expect(query(r[2]) == ["startHistoryId=1000", "maxResults=500", "historyTypes=messageAdded",
                                "historyTypes=messageDeleted", "historyTypes=labelAdded", "historyTypes=labelRemoved",
                                "pageToken=pt"])
    }

    @Test func queryValuesAreFullyEscaped() {
        let url = GmailClient.url("/gmail/v1/users/me/threads", query: [("q", "before:1700000000 a+b&c=d")])
        #expect(url.query(percentEncoded: true) == "q=before%3A1700000000%20a%2Bb%26c%3Dd")
    }

    @Test func historyNotFoundIsHistoryExpiredButOther404sAreNotFound() async throws {
        let http = FakeHTTPTransport()
        let c = client(http)
        await #expect(throws: GmailError.historyExpired) {
            _ = try await c.listHistory(startHistoryID: HistoryID(1), pageToken: nil, types: [], labelID: nil,
                                        maxResults: 500, priority: .sync)
        }
        await #expect(throws: GmailError.notFound("threads/zz")) {
            _ = try await c.getThread(id: "zz", format: .minimal, metadataHeaders: [], priority: .sync)
        }
    }

    @Test func decodingErrorsNameTheKeyPathNotValues() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(200, ["emailAddress": "secret@example.com"]) }
        do {
            _ = try await client(http).getProfile(priority: .sync)
            Issue.record("expected a decoding error")
        } catch GmailError.decoding(let detail) {
            #expect(detail.contains("historyId") && !detail.contains("secret"))
        }
    }

    @Test func fanOutKeepsOrderCapsConcurrencyAndReportsPerItemFailures() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/threads/") { request in
            try await Task.sleep(for: .milliseconds(3))
            let id = request.url.lastPathComponent
            if id == "t7" { return FakeHTTPTransport.json(404, ["error": ["code": 404, "message": "gone"]]) }
            return FakeHTTPTransport.json(200, ["id": id])
        }
        let ids = (0..<30).map { "t\($0)" }
        let results = try await client(http, batchSize: 1).getThreads(ids: ids, format: .metadata, metadataHeaders: [], priority: .sync)
        #expect(results.map(\.id) == ids)
        #expect(http.maxInFlight <= 8 && http.maxInFlight >= 2)
        for item in results {
            switch item.result {
            case .success(let t): #expect(t.id == item.id)
            case .failure(let e): #expect(item.id == "t7" && e == .notFound("threads/t7"))
            }
        }
    }

    @Test func fanOutThrowsWhenEveryItemWouldFail() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/messages/") { _ in FakeHTTPTransport.json(401, [:]) }
        await #expect(throws: GmailError.unauthorized) {
            _ = try await client(http, batchSize: 1).getMessages(ids: ["a", "b", "c"], format: .full, metadataHeaders: [], priority: .sync)
        }
    }

    @Test func writeAndUploadShapes() async throws {
        let http = FakeHTTPTransport()
        http.on("POST", "/gmail/v1/users/me/messages/batchModify") { _ in HTTPResponse(status: 204, headers: [:], body: Data()) }
        http.on("POST", "/upload/gmail/v1/users/me/messages") { _ in FakeHTTPTransport.json(200, ["id": "m1"]) }
        http.on("POST", "/upload/gmail/v1/users/me/drafts") { _ in FakeHTTPTransport.json(200, ["id": "r1"]) }
        let c = client(http)
        try await c.batchModifyMessages(ids: ["m1", "m2"], add: [], remove: ["INBOX"])
        _ = try await c.insertMessage(rawRFC822: Data("Subject: t\r\n\r\nx".utf8), labelIDs: ["Label_1"])
        _ = try await c.createDraft(rawRFC822: Data("Subject: d\r\n\r\ny".utf8), threadID: "t9")
        let r = http.requests
        let batch = try JSONSerialization.jsonObject(with: r[0].body ?? Data()) as? [String: Any]
        #expect(batch?["ids"] as? [String] == ["m1", "m2"] && batch?["removeLabelIds"] as? [String] == ["INBOX"])
        #expect(r[0].headers["Content-Type"] == "application/json")
        #expect(r[1].url.path() == "/upload/gmail/v1/users/me/messages")
        #expect(query(r[1]) == ["uploadType=multipart", "internalDateSource=receivedTime"])
        let insertBody = String(decoding: r[1].body ?? Data(), as: UTF8.self)
        #expect(insertBody.contains("{\"labelIds\":[\"Label_1\"]}") && insertBody.contains("Content-Type: message/rfc822"))
        #expect(r[1].headers["Content-Type"]?.hasPrefix("multipart/related; boundary=") == true)
        #expect(String(decoding: r[2].body ?? Data(), as: UTF8.self).contains("{\"message\":{\"threadId\":\"t9\"}}"))
    }

    @Test func factoryClientsWriteWithAModifyGrantAndAreCachedPerAccount() async throws {
        for scopes in [[GmailScope.modify], [GmailScope.modify, GmailScope.readonly, "openid"]] {
            let http = FakeHTTPTransport()
            http.on("POST", "/gmail/v1/users/me/messages/m1/modify") { _ in FakeHTTPTransport.json(200, ["id": "m1"]) }
            http.on("GET", "/gmail/v1/users/me/labels") { _ in FakeHTTPTransport.json(200, ["labels": []]) }
            let factory = DefaultGmailClientFactory(apiTransport: http,
                                                    config: GmailClientConfig(userAgent: "t"), clock: InstantClock()) { _ in
                (StaticTokenProvider(), scopes)
            }
            let api = try factory.client(for: "Me@Example.com")
            #expect(api.accountEmail == "me@example.com")
            _ = try await api.listLabels()
            _ = try await api.modifyMessage(id: "m1", add: [], remove: ["INBOX"])
            #expect(http.requests.filter { $0.method != "GET" }.count == 1, "\(scopes)")
            #expect(try factory.gmailClient(for: "me@example.com") === factory.gmailClient(for: "ME@example.com"))
        }
    }

    @Test func factoryWithoutAStoredTokenNeedsReauth() throws {
        let factory = DefaultGmailClientFactory(tokenStore: InMemoryTokenStore(),
                                                oauthClient: OAuthClientConfig(clientID: "client.apps.example",
                                                                               authURI: URL(string: "https://auth.invalid")!,
                                                                               tokenURI: URL(string: "https://token.invalid")!),
                                                apiTransport: FakeHTTPTransport(), tokenTransport: FakeHTTPTransport(),
                                                config: GmailClientConfig(userAgent: "t"), clock: InstantClock())
        #expect(throws: GmailError.reauthRequired) { _ = try factory.client(for: "me@example.com") }
    }

    @Test func fullStackAgainstFakeGmailReadsWithGETsOnly() async throws {
        let gmail = FakeGmail()
        let (_, thread) = await gmail.deliver(subject: "Synthetic", body: "Hello there", html: "<p>Hello there</p>")
        let wire = FakeGmailTransport(gmail)
        let factory = DefaultGmailClientFactory(apiTransport: wire,
                                                config: GmailClientConfig(userAgent: "t"), clock: InstantClock()) { _ in
            (StaticTokenProvider(), [GmailScope.modify])
        }
        let api = try factory.client(for: "me@example.com")
        let profile = try await api.getProfile(priority: .interactive)
        #expect(profile.emailAddress == "me@example.com")
        #expect(try await api.listLabels().contains { $0.id == "INBOX" })
        let list = try await api.listThreads(ListQuery(labelIDs: ["INBOX"], maxResults: 50), priority: .interactive)
        #expect(list.threads?.map(\.id) == [thread])
        let meta = try await api.getThread(id: thread, format: .metadata, metadataHeaders: ["Subject"], priority: .sync)
        #expect(meta.messages?.first?.payload?.headers?.map(\.name) == ["Subject"])
        let full = try await api.getThread(id: thread, format: .full, metadataHeaders: [], priority: .sync)
        #expect(full.messages?.first?.payload?.parts?.count == 2)
        await gmail.expireAllHistory()
        await #expect(throws: GmailError.historyExpired) {
            _ = try await api.listHistory(startHistoryID: HistoryID(1), pageToken: nil, types: [], labelID: nil,
                                          maxResults: 500, priority: .sync)
        }
        #expect(wire.nonGETRequests.isEmpty, "reading never writes")
    }
}
