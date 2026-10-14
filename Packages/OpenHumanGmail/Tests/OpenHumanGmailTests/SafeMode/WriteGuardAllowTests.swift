import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct WriteGuardAllowTests {
    private let api = WG.api, upload = WG.upload

    private func jsonBody(_ request: HTTPRequest?) -> [String: Any] {
        guard let body = request?.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func parts(_ request: HTTPRequest?) -> (meta: [String: Any], message: Data)? {
        guard let request, case .success(let upload) = Upload.parse(request),
              let meta = try? JSONSerialization.jsonObject(with: upload.metadata) as? [String: Any] else { return nil }
        return (meta, upload.message)
    }

    @Test func readsPass() async throws {
        let reads = ["profile", "settings/sendAs", "labels", "labels/Label_U", "threads?labelIds=INBOX&maxResults=50",
                     "threads/t9?format=full", "messages/m9?format=raw", "messages/m9/attachments/a1",
                     "history?startHistoryId=1&historyTypes=messageAdded", "drafts", "drafts/d9?format=full"]
        for path in reads {
            try await expectWriteAllowed(WG.request("GET", api + path), "GET \(path)")
        }
        let batch = WG.request("POST", "https://gmail.googleapis.com/batch/gmail/v1",
                               body: Data("--b\r\nContent-Type: application/http\r\n\r\nGET /gmail/v1/users/me/threads/t9 HTTP/1.1\r\n\r\n--b--\r\n".utf8),
                               extraHeaders: ["Content-Type": "multipart/mixed; boundary=b"])
        try await expectWriteAllowed(batch, "all-GET batch")
    }

    @Test func labelCreateUnderOpenHumanPasses() async throws {
        for name in ["OpenHuman/Test", "OpenHuman/Snoozed", "OpenHuman/Snoozed/20261012T0900Z", "OpenHuman/Agent"] {
            let forwarded = try await expectWriteAllowed(
                WG.json("POST", api + "labels", ["name": name, "labelListVisibility": "labelHide",
                                                 "messageListVisibility": "hide"]), name)
            let body = jsonBody(forwarded)
            #expect(body["name"] as? String == name && body["labelListVisibility"] as? String == "labelHide")
            #expect(body.count == 3)
        }
        try await expectWriteAllowed(WG.json("POST", api + "labels", ["name": "OpenHuman/Test"]), "name only")
    }

    @Test func syntheticInsertPassesRebuilt() async throws {
        let request = WG.insert()
        let forwarded = try #require(try await expectWriteAllowed(request, "insert"))
        #expect(forwarded.url == request.url)
        #expect(forwarded.method == "POST")
        let (meta, message) = try #require(parts(forwarded))
        #expect(meta as NSDictionary == ["labelIds": ["Label_T", "INBOX", "UNREAD"]] as NSDictionary)
        #expect(message == WG.synthetic)
        #expect(forwarded.body != request.body)
        #expect(forwarded.headers["Authorization"] == "Bearer test-access-token")
        try await expectWriteAllowed(
            WG.insert(url: upload + "messages?internalDateSource=receivedTime&uploadType=multipart"), "query order")
        try await expectWriteAllowed(WG.insert(labelIDs: ["Label_T"]), "Test only")
        try await expectWriteAllowed(WG.insert(labelIDs: ["Label_T", "Label_S", "STARRED", "IMPORTANT"]), "more labels")
        let reply = SyntheticThreads.message(runID: "run1", index: 2, subjectIndex: 1, to: "me@example.com",
                                             date: Date(timeIntervalSince1970: 1_790_000_000),
                                             inReplyTo: "<oh-test.run1.1@openhuman.invalid>")
        try await expectWriteAllowed(WG.insert(message: reply), "synthetic reply")
        try await expectWriteAllowed(WG.insert(message: Data(String(decoding: WG.synthetic, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").utf8)), "LF message")
    }

    @Test func labelChangesOnTestMessagesPass() async throws {
        let forwarded = try await expectWriteAllowed(
            WG.json("POST", api + "messages/batchModify",
                    ["ids": ["m1", "m2"], "addLabelIds": ["Label_S", "STARRED"], "removeLabelIds": ["INBOX", "UNREAD"]]),
            "batchModify")
        let body = jsonBody(forwarded)
        #expect(body["ids"] as? [String] == ["m1", "m2"])
        #expect(body["addLabelIds"] as? [String] == ["Label_S", "STARRED"])
        #expect(body["removeLabelIds"] as? [String] == ["INBOX", "UNREAD"])
        try await expectWriteAllowed(WG.json("POST", api + "messages/batchModify", ["ids": ["m1"], "removeLabelIds": ["INBOX"]]),
                                     "batchModify remove only")
        try await expectWriteAllowed(WG.json("POST", api + "messages/m1/modify", ["addLabelIds": ["TRASH"]]), "modify")
        try await expectWriteAllowed(WG.json("POST", api + "messages/m2/modify", ["removeLabelIds": ["Label_T"]]),
                                     "modify removes an OpenHuman label")
        for system in WriteRules.systemLabels.sorted() {
            try await expectWriteAllowed(WG.json("POST", api + "messages/m1/modify", ["addLabelIds": [system]]), system)
        }
        for path in ["messages/m1/trash", "messages/m2/untrash", "threads/t1/trash", "threads/t1/untrash"] {
            let forwarded = try await expectWriteAllowed(WG.request("POST", api + path), path)
            #expect(forwarded?.body == nil)
        }
    }

    @Test func ownDraftWritesPass() async throws {
        let create = try await expectWriteAllowed(
            WG.upload("POST", upload + "drafts?uploadType=multipart", metadata: #"{"message":{}}"#, message: WG.synthetic),
            "create, new thread")
        #expect((parts(create)?.meta["message"] as? [String: Any])?.isEmpty == true)
        try await expectWriteAllowed(WG.upload("POST", upload + "drafts?uploadType=multipart", metadata: "{}",
                                               message: WG.synthetic), "create, empty metadata")
        let inThread = try await expectWriteAllowed(
            WG.upload("POST", upload + "drafts?uploadType=multipart", metadata: #"{"message":{"threadId":"t1"}}"#,
                      message: WG.message(["From: me@example.com", "Subject: anything"])),
            "create in a test thread (draft content is not checked)")
        #expect((parts(inThread)?.meta["message"] as? [String: Any])?["threadId"] as? String == "t1")
        let update = try await expectWriteAllowed(
            WG.upload("PUT", upload + "drafts/d1?uploadType=multipart", metadata: #"{"id":"d1","message":{"threadId":"t1"}}"#,
                      message: WG.synthetic), "update")
        #expect(parts(update)?.meta["id"] as? String == "d1")
        try await expectWriteAllowed(WG.upload("PUT", upload + "drafts/d1?uploadType=multipart", metadata: #"{"message":{}}"#,
                                               message: WG.synthetic), "update without metadata id")
        try await expectWriteAllowed(WG.request("DELETE", api + "drafts/d1"), "delete")
    }

    @Test func insertTeachesTheMessageAndThreadThenTrashPasses() async throws {
        let (guarded, inner, store) = WG.guarded { request in
            request.method == "POST" && request.url.path().hasPrefix("/upload/")
                ? jsonResponse(200, ["id": "m5", "threadId": "m5", "labelIds": ["Label_T"]])
                : jsonResponse(200, ["id": "m5"])
        }
        await #expect(throws: TransportError.blockedBySafeMode("POST /gmail/v1/users/me/threads/m5/trash")) {
            _ = try await guarded.send(WG.request("POST", api + "threads/m5/trash"))
        }
        _ = try await guarded.send(WG.insert())
        let after = await store.snapshot
        #expect(after.containsMessage("m5") && after.containsThread("m5"))
        _ = try await guarded.send(WG.request("POST", api + "threads/m5/trash"))
        _ = try await guarded.send(WG.json("POST", api + "messages/batchModify", ["ids": ["m5", "m1"], "removeLabelIds": ["INBOX"]]))
        #expect(inner.requests.count == 3)
    }

    @Test func insertIntoAnUnknownThreadDoesNotAllowlistThatThread() async throws {
        for (thread, joins) in [("t9", false), ("t1", true), ("m6", true)] {
            let (guarded, _, store) = WG.guarded { _ in jsonResponse(200, ["id": "m6", "threadId": thread]) }
            _ = try await guarded.send(WG.insert())
            let snapshot = await store.snapshot
            #expect(snapshot.containsMessage("m6"))
            #expect(snapshot.containsThread(thread) == joins, "\(thread)")
        }
    }

    @Test func draftCreateAndUpdateTeachTheirIds() async throws {
        let (guarded, _, store) = WG.guarded { request in
            switch request.method {
            case "POST": return jsonResponse(200, ["id": "d7", "message": ["id": "m7", "threadId": "t7"]])
            case "PUT": return jsonResponse(200, ["id": "d7", "message": ["id": "m8", "threadId": "t7"]])
            default: return HTTPResponse(status: 204, headers: [:], body: Data())
            }
        }
        _ = try await guarded.send(WG.upload("POST", upload + "drafts?uploadType=multipart", metadata: #"{"message":{}}"#,
                                             message: WG.synthetic))
        var snapshot = await store.snapshot
        #expect(snapshot.containsDraft("d7") && snapshot.containsMessage("m7"))
        #expect(!snapshot.containsThread("t7"))
        _ = try await guarded.send(WG.upload("PUT", upload + "drafts/d7?uploadType=multipart", metadata: #"{"id":"d7"}"#,
                                             message: WG.synthetic))
        snapshot = await store.snapshot
        #expect(snapshot.containsMessage("m8"))
        _ = try await guarded.send(WG.request("DELETE", api + "drafts/d7"))
    }

    @Test func labelResponsesTeachOpenHumanLabelIds() async throws {
        var empty = WG.allowlist
        empty.labels = ["Label_X": "OpenHuman/Renamed"]
        let (guarded, _, store) = WG.guarded(empty) { request in
            switch (request.method, request.url.path()) {
            case ("GET", "/gmail/v1/users/me/labels"):
                return jsonResponse(200, ["labels": [["id": "INBOX", "name": "INBOX", "type": "system"],
                                                     ["id": "Label_U", "name": "Work", "type": "user"],
                                                     ["id": "Label_X", "name": "Projects", "type": "user"],
                                                     ["id": "Label_T", "name": "OpenHuman/Test", "type": "user"],
                                                     ["id": "bad id", "name": "OpenHuman/Weird", "type": "user"]]])
            case ("GET", _): return jsonResponse(200, ["id": "Label_A", "name": "OpenHuman/Agent"])
            default: return jsonResponse(200, ["id": "Label_N", "name": "OpenHuman/Snoozed/20261012T0900Z"])
            }
        }
        _ = try await guarded.send(WG.request("GET", api + "labels"))
        var snapshot = await store.snapshot
        #expect(snapshot.labels == ["Label_T": "OpenHuman/Test"])
        #expect(snapshot.testLabelID == "Label_T")
        _ = try await guarded.send(WG.request("GET", api + "labels/Label_A"))
        _ = try await guarded.send(WG.json("POST", api + "labels", ["name": "OpenHuman/Snoozed/20261012T0900Z"]))
        snapshot = await store.snapshot
        #expect(snapshot.labels.keys.sorted() == ["Label_A", "Label_N", "Label_T"])
        _ = try await guarded.send(WG.json("POST", api + "messages/m1/modify", ["addLabelIds": ["Label_N"]]))
    }

    @Test func messagesOfAnAllowlistedThreadCount() async throws {
        let (guarded, _, store) = WG.guarded { request in
            switch request.url.path() {
            case "/gmail/v1/users/me/threads/t1":
                return jsonResponse(200, ["id": "t1", "messages": [["id": "m1", "threadId": "t1"],
                                                                   ["id": "m3", "threadId": "t1"],
                                                                   ["id": "mX", "threadId": "t9"]]])
            case "/gmail/v1/users/me/threads/t9":
                return jsonResponse(200, ["id": "t9", "messages": [["id": "m9", "threadId": "t9"]]])
            case "/gmail/v1/users/me/messages/m4": return jsonResponse(200, ["id": "m4", "threadId": "t1"])
            case "/gmail/v1/users/me/messages/m9": return jsonResponse(200, ["id": "m9", "threadId": "t9"])
            case "/gmail/v1/users/me/drafts/d1": return jsonResponse(200, ["id": "d1", "message": ["id": "m6"]])
            case "/gmail/v1/users/me/drafts/d9": return jsonResponse(200, ["id": "d9", "message": ["id": "m99"]])
            default: return jsonResponse(404, ["error": ["code": 404]])
            }
        }
        for path in ["threads/t1", "threads/t9", "messages/m4", "messages/m9", "drafts/d1", "drafts/d9"] {
            _ = try await guarded.send(WG.request("GET", api + path))
        }
        let snapshot = await store.snapshot
        #expect(snapshot.messageIDs == ["m1", "m2", "m3", "m4", "m6"])
        #expect(snapshot.threadIDs == ["t1"] && snapshot.draftIDs == ["d1"])
    }

    @Test func failedResponsesTeachNothing() async throws {
        let (guarded, _, store) = WG.guarded { _ in jsonResponse(409, ["id": "m5", "threadId": "t5"]) }
        _ = try await guarded.send(WG.insert())
        _ = try await guarded.send(WG.json("POST", api + "labels", ["name": "OpenHuman/Test"]))
        #expect(await store.snapshot == WG.allowlist)
    }

    @Test func everyGmailAPIWriteMethodTable() async throws {
        let (guarded, inner, _) = WG.guarded()
        let clock = InstantClock()
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: guarded,
                                 config: GmailClientConfig(userAgent: "t"), clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock),
                                 jitter: { 0 })
        let real = WG.message(replacing: "From", with: "From: Alice <alice@example.com>")
        typealias Call = @Sendable () async throws -> Void
        let table: [(String, allowed: Call, refused: Call?)] = [
            ("createLabel", { _ = try await client.createLabel(name: "OpenHuman/Test", labelListVisibility: nil, messageListVisibility: nil) },
             { _ = try await client.createLabel(name: "Work", labelListVisibility: nil, messageListVisibility: nil) }),
            ("insertMessage", { _ = try await client.insertMessage(rawRFC822: WG.synthetic, labelIDs: ["Label_T", "INBOX"]) },
             { _ = try await client.insertMessage(rawRFC822: WG.synthetic, labelIDs: ["INBOX"]) }),
            ("insertMessage non-synthetic", { _ = try await client.insertMessage(rawRFC822: WG.synthetic, labelIDs: ["Label_T"]) },
             { _ = try await client.insertMessage(rawRFC822: real, labelIDs: ["Label_T"]) }),
            ("batchModifyMessages", { try await client.batchModifyMessages(ids: ["m1", "m2"], add: [], remove: ["INBOX"]) },
             { try await client.batchModifyMessages(ids: ["m1", "m9"], add: [], remove: ["INBOX"]) }),
            ("batchModifyMessages label", { try await client.batchModifyMessages(ids: ["m1"], add: ["Label_S"], remove: []) },
             { try await client.batchModifyMessages(ids: ["m1"], add: ["Label_U"], remove: []) }),
            ("modifyMessage", { _ = try await client.modifyMessage(id: "m1", add: ["STARRED"], remove: []) },
             { _ = try await client.modifyMessage(id: "m9", add: ["STARRED"], remove: []) }),
            ("trashMessage", { _ = try await client.trashMessage(id: "m1") }, { _ = try await client.trashMessage(id: "m9") }),
            ("untrashMessage", { _ = try await client.untrashMessage(id: "m1") }, { _ = try await client.untrashMessage(id: "m9") }),
            ("trashThread", { _ = try await client.trashThread(id: "t1") }, { _ = try await client.trashThread(id: "t9") }),
            ("untrashThread", { _ = try await client.untrashThread(id: "t1") }, { _ = try await client.untrashThread(id: "t9") }),
            ("createDraft", { _ = try await client.createDraft(rawRFC822: real, threadID: "t1") },
             { _ = try await client.createDraft(rawRFC822: real, threadID: "t9") }),
            ("createDraft no thread", { _ = try await client.createDraft(rawRFC822: real, threadID: nil) }, nil),
            ("updateDraft", { _ = try await client.updateDraft(id: "d1", rawRFC822: real, threadID: nil) },
             { _ = try await client.updateDraft(id: "d9", rawRFC822: real, threadID: nil) }),
            ("updateDraft thread", { _ = try await client.updateDraft(id: "d1", rawRFC822: real, threadID: "t1") },
             { _ = try await client.updateDraft(id: "d1", rawRFC822: real, threadID: "t9") }),
            ("deleteDraft", { try await client.deleteDraft(id: "d1") }, { try await client.deleteDraft(id: "d9") }),
        ]
        for (name, allowed, refused) in table {
            let before = inner.requests.count
            do { try await allowed() } catch { Issue.record("\(name) allowed case failed: \(error)") }
            #expect(inner.requests.count == before + 1, "\(name) allowed")
            if let refused {
                do {
                    try await refused()
                    Issue.record("\(name): the refused case passed")
                } catch GmailError.transport(.blockedBySafeMode) {
                } catch {
                    Issue.record("\(name): unexpected error \(error)")
                }
                #expect(inner.requests.count == before + 1, "\(name): the refused call reached the wire")
            }
        }
        let before = inner.requests.count
        for thread in [nil, "t1", "t9"] as [String?] {
            await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /upload/gmail/v1/users/me/messages/send"))) {
                _ = try await client.sendMessage(rawRFC822: WG.synthetic, threadID: thread)
            }
        }
        for draft in ["d1", "d9"] {
            await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /gmail/v1/users/me/drafts/send"))) {
                _ = try await client.sendDraft(id: draft)
            }
        }
        #expect(inner.requests.count == before)
        #expect(inner.requests.allSatisfy { !$0.url.path().contains("send") })
    }
}
