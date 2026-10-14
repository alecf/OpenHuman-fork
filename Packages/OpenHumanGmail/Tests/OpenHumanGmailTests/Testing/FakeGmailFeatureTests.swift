import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing

@Suite struct FakeGmailFeatureTests {
    static func raw(_ lines: String...) -> Data { Data((lines.joined(separator: "\r\n")).utf8) }

    static func client(_ gmail: FakeGmail, clock: InstantClock = InstantClock()) -> (GmailClient, FakeGmailTransport) {
        let transport = FakeGmailTransport(gmail)
        return (GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(),
                            transport: transport, config: GmailClientConfig(userAgent: "t"),
                            clock: clock, metrics: nil), transport)
    }

    @Test func bccIsStrippedFromDeliveriesButKeptInTheSentCopy() async throws {
        let gmail = FakeGmail()
        let message = Self.raw("From: me@example.com", "To: bob@example.com", "Cc: carol@example.com",
                               "Bcc: dave@example.com,", " erin@example.com", "Subject: S", "", "Body")
        let draft = try await gmail.createDraft(rawRFC822: message, threadID: nil)
        let sent = try await gmail.sendDraft(id: draft.id)
        let deliveries = await gmail.deliveries()
        #expect(deliveries.map(\.recipient) == ["bob@example.com", "carol@example.com", "dave@example.com", "erin@example.com"])
        for d in deliveries {
            let text = String(decoding: d.raw, as: UTF8.self)
            #expect(!text.lowercased().contains("bcc") && !text.contains("dave@") && !text.contains("erin@"))
            #expect(text.contains("To: bob@example.com") && text.hasSuffix("\r\n\r\nBody"))
            #expect(d.sentMessageID == sent.id)
        }
        let stored = try await gmail.getMessage(id: sent.id, format: .full, metadataHeaders: [], priority: .interactive)
        #expect(stored.payload?.headers?.contains { $0.name == "Bcc" } == true)
        _ = try await gmail.sendMessage(rawRFC822: message, threadID: nil)
        #expect(await gmail.deliveries().count == 8)
    }

    @Test func sendDraftMovesToSentWithNewIDAndRecordsHistory() async throws {
        let gmail = FakeGmail()
        let start = await gmail.currentHistoryID
        let draft = try await gmail.createDraft(rawRFC822: Self.raw("To: bob@example.com", "Subject: D", "", "Hi"),
                                                threadID: nil)
        let draftMessage = try #require(draft.message?.id)
        let sent = try await gmail.sendDraft(id: draft.id)
        #expect(sent.id != draftMessage)
        let labels = await gmail.labelIDs(ofMessage: sent.id)
        #expect(labels?.contains("SENT") == true && labels?.contains("DRAFT") == false)
        #expect(await gmail.labelIDs(ofMessage: draftMessage) == nil)
        let history = try await gmail.listHistory(startHistoryID: start, pageToken: nil, types: [], labelID: nil,
                                                  maxResults: 100, priority: .sync)
        let records = history.history ?? []
        #expect(records.first?.messagesAdded?.first?.message.id == draftMessage)
        #expect(records.contains { $0.messagesDeleted?.first?.message.id == draftMessage })
        #expect(records.last?.messagesAdded?.first?.message.id == sent.id)
    }

    @Test func insertMessageParsesMultipartRawAndValidatesLabels() async throws {
        let gmail = FakeGmail()
        let multipart = Self.raw("From: Alice <alice@example.com>", "To: me@example.com", "Subject: Insert",
                                 "MIME-Version: 1.0", "Content-Type: multipart/alternative; boundary=\"b\"", "",
                                 "--b", "Content-Type: text/plain; charset=utf-8", "", "plain part",
                                 "--b", "Content-Type: text/html; charset=utf-8", "", "<p>html part</p>", "--b--", "")
        let label = await gmail.addUserLabel("OpenHuman/Test")
        let inserted = try await gmail.insertMessage(rawRFC822: multipart, labelIDs: ["INBOX", label])
        let full = try await gmail.getMessage(id: inserted.id, format: .full, metadataHeaders: [], priority: .interactive)
        #expect(full.labelIds?.sorted() == ["INBOX", label].sorted())
        #expect(full.payload?.mimeType == "multipart/alternative" && full.payload?.parts?.count == 2)
        #expect(full.snippet?.hasPrefix("plain part") == true)
        let contentTypes = full.payload?.headers?.filter { $0.name.lowercased() == "content-type" }
        #expect(contentTypes?.count == 1)
        await #expect(throws: GmailError.badRequest(reason: "invalidArgument", message: "Invalid label")) {
            _ = try await gmail.insertMessage(rawRFC822: multipart, labelIDs: ["Label_nope"])
        }
        #expect(await gmail.callCount(.insertMessage) == 2)
    }

    @Test func uploadsAndDraftSendWorkThroughTheRESTFront() async throws {
        let gmail = FakeGmail()
        let (client, transport) = Self.client(gmail)
        let inserted = try await client.insertMessage(rawRFC822: Self.raw("To: me@example.com", "Subject: A", "", "x"),
                                                      labelIDs: ["INBOX"])
        #expect(await gmail.labelIDs(ofMessage: inserted.id) == ["INBOX"])
        let draft = try await client.createDraft(rawRFC822: Self.raw("To: b@example.com", "Bcc: c@example.com", "Subject: B", "", "y"),
                                                 threadID: nil)
        let updated = try await client.updateDraft(id: draft.id, rawRFC822: Self.raw("To: b@example.com", "Subject: B2", "", "z"),
                                                   threadID: nil)
        #expect(updated.id == draft.id)
        let sent = try await client.sendDraft(id: draft.id)
        #expect(await gmail.labelIDs(ofMessage: sent.id)?.contains("SENT") == true)
        #expect(await gmail.deliveries().map(\.recipient) == ["b@example.com"])
        #expect(transport.requests.contains { $0.url.path().hasSuffix("/drafts/send") })
    }

    @Test func expiryBoundariesAndExpireAllHistory() async throws {
        let gmail = FakeGmail()
        let start = await gmail.currentHistoryID
        await gmail.deliver(subject: "a")
        await gmail.deliver(subject: "b")
        let mid = await gmail.currentHistoryID
        await gmail.expireHistory(before: mid)
        await #expect(throws: GmailError.historyExpired) {
            _ = try await gmail.listHistory(startHistoryID: start, pageToken: nil, types: [], labelID: nil,
                                            maxResults: 10, priority: .sync)
        }
        let ok = try await gmail.listHistory(startHistoryID: mid, pageToken: nil, types: [], labelID: nil,
                                             maxResults: 10, priority: .sync)
        #expect(ok.history == nil)
        await gmail.deliver(subject: "c")
        await gmail.expireAllHistory()
        await #expect(throws: GmailError.historyExpired) {
            _ = try await gmail.listHistory(startHistoryID: mid, pageToken: nil, types: [], labelID: nil,
                                            maxResults: 10, priority: .sync)
        }
        let fresh = try await gmail.getProfile(priority: .sync).historyId
        let valid = try await gmail.listHistory(startHistoryID: HistoryID(UInt64(fresh)!), pageToken: nil, types: [],
                                                labelID: nil, maxResults: 10, priority: .sync)
        #expect(valid.history == nil)
    }

    @Test func historyExpiryIsA404OnTheRESTFront() async throws {
        let gmail = FakeGmail()
        let (client, _) = Self.client(gmail)
        await gmail.deliver()
        await gmail.expireAllHistory()
        await #expect(throws: GmailError.historyExpired) {
            _ = try await client.listHistory(startHistoryID: HistoryID(1), pageToken: nil, types: [], labelID: nil,
                                             maxResults: 10, priority: .sync)
        }
    }

    @Test func webSideLabelRenameAndArchiveAreRecordedOnce() async throws {
        let gmail = FakeGmail()
        let label = await gmail.addUserLabel("Old")
        let (_, thread) = await gmail.deliver()
        let start = await gmail.currentHistoryID
        await gmail.simulateWebLabelRename(labelID: label, newName: "New")
        #expect(try await gmail.getLabel(id: label).name == "New")
        await gmail.simulateWebArchive(threadID: thread)
        let h = try await gmail.listHistory(startHistoryID: start, pageToken: nil, types: [.labelRemoved], labelID: nil,
                                            maxResults: 10, priority: .sync)
        #expect(h.history?.count == 1)
    }

    @Test func failNextCountsAndLatencyUsesTheVirtualClock() async throws {
        let clock = InstantClock()
        let gmail = FakeGmail(clock: clock)
        await gmail.failNext(.getProfile, with: .rateLimited(retryAfter: nil), count: 2)
        await gmail.latency(.getProfile, .seconds(3))
        for _ in 0..<2 { await #expect(throws: GmailError.self) { _ = try await gmail.getProfile(priority: .sync) } }
        _ = try await gmail.getProfile(priority: .sync)
        #expect(clock.sleeps == [3, 3, 3])
        let calls = await gmail.callCount(.getProfile), spent = await gmail.units(for: .getProfile)
        #expect(calls == 3 && spent == 3)
        await gmail.resetAccounting()
        #expect(await gmail.unitsUsed == 0)
    }

    @Test func ambiguousFailureAppliesOnceForEveryWriteMethod() async throws {
        let gmail = FakeGmail()
        let (id, _) = await gmail.deliver()
        await gmail.ambiguousFailureAfterCommit(.modifyMessage)
        await #expect(throws: GmailError.transport(.timedOut)) {
            _ = try await gmail.modifyMessage(id: id, add: ["STARRED"], remove: [])
        }
        #expect(await gmail.labelIDs(ofMessage: id)?.contains("STARRED") == true)
        _ = try await gmail.modifyMessage(id: id, add: [], remove: ["STARRED"])
        await gmail.ambiguousFailureAfterCommit(.createDraft)
        await #expect(throws: GmailError.transport(.timedOut)) {
            _ = try await gmail.createDraft(rawRFC822: Self.raw("Subject: x", "", "y"), threadID: nil)
        }
        #expect(try await gmail.listDrafts(pageToken: nil, q: nil, maxResults: 10).drafts?.count == 1)
    }

    @Test func afterNextInterleavesAnElsewhereChange() async throws {
        let gmail = FakeGmail()
        let (id, _) = await gmail.deliver()
        await gmail.afterNext(.getMessage) { $0.modifyLabels(messageID: id, add: ["STARRED"]) }
        let first = try await gmail.getMessage(id: id, format: .minimal, metadataHeaders: [], priority: .sync)
        #expect(first.labelIds?.contains("STARRED") == false)
        let second = try await gmail.getMessage(id: id, format: .minimal, metadataHeaders: [], priority: .sync)
        #expect(second.labelIds?.contains("STARRED") == true)
    }

    @Test func batchEndpointServesInnerGETsInOrderThroughTheClient() async throws {
        let gmail = FakeGmail()
        let (a, _) = await gmail.deliver(subject: "A"), (b, _) = await gmail.deliver(subject: "B")
        let (client, transport) = Self.client(gmail)
        let result = try await client.getMessages(ids: [b, a, "missing"], format: .metadata, metadataHeaders: ["Subject"],
                                                  priority: .sync)
        #expect(result.count == 3)
        #expect(transport.batchRequests.count == 1)
        #expect(transport.nonGETRequests.isEmpty)
    }

    @Test func fakeHTTPTransportRoutesRecordsAndInjectsFaults() async throws {
        let transport = FakeHTTPTransport()
        transport.on("GET", "/a") { _ in FakeHTTPTransport.json(200, ["who": "a"]) }
        transport.on("GET", "/a/b") { _ in FakeHTTPTransport.json(200, ["who": "ab"]) }
        let url = { (p: String) in URL(string: "https://example.invalid" + p)! }
        let get = { (p: String) in HTTPRequest(method: "GET", url: url(p), headers: [:]) }
        #expect(String(decoding: try await transport.send(get("/a/b/c")).body, as: UTF8.self).contains("\"ab\""))
        #expect(String(decoding: try await transport.send(get("/a/x")).body, as: UTF8.self).contains("\"a\""))
        #expect(try await transport.send(get("/zzz")).status == 404)
        transport.failNext(.timedOut, count: 1)
        await #expect(throws: TransportError.timedOut) { _ = try await transport.send(get("/a")) }
        #expect(try await transport.send(get("/a")).status == 200)
        #expect(transport.requests.map { $0.url.path() } == ["/a/b/c", "/a/x", "/zzz", "/a", "/a"])
    }

    @Test func fixtureTransportReplaysFromADirectoryAndFailsLoudlyWithoutAMatch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"request":{"method":"GET","path":"/gmail/v1/users/me/profile"},"response":{"status":200,"headers":{"content-type":"application/json"},"body":{"emailAddress":"user1@example.com","historyId":"7"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("profile.json"))
        try Data(#"{"request":{"method":"GET","path":"/gmail/v1/users/me/threads","query":{"q":"in:inbox"}},"response":{"status":200,"body":"{\"threads\":[]}"}}"#.utf8)
            .write(to: dir.appendingPathComponent("threads-inbox.json"))
        try Data(#"{"request":{"method":"GET","path":"/gmail/v1/users/me/threads"},"response":{"status":404,"body":"general"}}"#.utf8)
            .write(to: dir.appendingPathComponent("threads-any.json"))
        let transport = try FixtureTransport(directory: dir)
        #expect(transport.fixtures.count == 3)
        let base = "https://gmail.googleapis.com/gmail/v1/users/me/"
        let profile = try await transport.send(HTTPRequest(method: "GET", url: URL(string: base + "profile")!, headers: [:]))
        #expect(profile.status == 200 && String(decoding: profile.body, as: UTF8.self).contains("user1@example.com"))
        let inbox = try await transport.send(HTTPRequest(method: "GET", url: URL(string: base + "threads?q=in:inbox&maxResults=5")!, headers: [:]))
        #expect(String(decoding: inbox.body, as: UTF8.self) == #"{"threads":[]}"#)
        let other = try await transport.send(HTTPRequest(method: "GET", url: URL(string: base + "threads?q=x")!, headers: [:]))
        #expect(other.status == 404)
        await #expect(throws: FixtureTransport.Failure.self) {
            _ = try await transport.send(HTTPRequest(method: "POST", url: URL(string: base + "profile")!, headers: [:]))
        }
        #expect(transport.requests.count == 4)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        #expect(throws: FixtureTransport.Failure.unreadable(name: "bad.json")) { _ = try FixtureTransport(directory: dir) }
    }
}
