import Foundation
import Testing
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME

@Suite struct GmailContractsCompileTests {
    @Test func authTypes() {
        let token = StoredToken(refreshToken: "r", grantedScopes: ["https://www.googleapis.com/auth/gmail.modify"], clientID: "c")
        let profile = GmailProfile(emailAddress: "me@example.com", historyId: "42")
        let result = OAuthResult(email: "me@example.com", token: token, profile: profile)
        #expect(result.token.accessToken == nil)
        let config = OAuthClientConfig(clientID: "c", authURI: URL(string: "https://accounts.google.com/o/oauth2/auth")!,
                                       tokenURI: URL(string: "https://oauth2.googleapis.com/token")!)
        #expect(config.clientSecret == nil)
        #expect(OAuthClientSource.storeFile != .missing)
        #expect(OAuthError.insufficientScopes(missing: ["x"]) != .reauthRequired)
    }

    @Test func transportAndErrors() {
        let request = HTTPRequest(method: "GET", url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!, headers: [:])
        #expect(request.timeout == .seconds(30))
        let response = HTTPResponse(status: 204, headers: ["content-type": "application/json"], body: Data())
        #expect(response.status == 204)
        #expect(GmailError.transport(.connectionLost(requestMayHaveBeenSent: true)) != .historyExpired)
        #expect(RetryPolicy.background.maxAttempts == 6 && RetryPolicy.interactive.maxAttempts == 3)
        #expect(RetryPolicy.background.maxRetryAfter == .seconds(300))
        #expect(RequestPriority.allSorted == [.backfill, .sync, .queue, .interactive])
        let config = GmailClientConfig(userAgent: "OpenHumanMail/0.1.0 (gzip)")
        #expect(config.unitsPerMinute == 6000 && config.batchSize == 25 && config.maxConcurrentRequests == 8)
    }

    @Test func dtosDecodeAndTypedValues() throws {
        let json = """
        {"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"historyId":"12345","internalDate":"1791795600000",
         "payload":{"partId":"","mimeType":"text/plain","headers":[{"name":"Subject","value":"Hi"}],"body":{"size":2,"data":"aGk"}},
         "unknownField":true}
        """
        let message = try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
        #expect(message.historyIDValue == HistoryID(12345))
        #expect(message.internalDateValue == Date(timeIntervalSince1970: 1_791_795_600))
        #expect(message.payload?.headers?.first?.value == "Hi")
        _ = GmailThread(id: "t1", messages: [message])
        _ = GmailLabel(id: "Label_1", name: "Work", color: GmailLabelColor(textColor: "#000", backgroundColor: "#fff"))
        _ = GmailDraft(id: "r1", message: message)
        _ = GmailHistoryRecord(id: "1", messagesAdded: [GmailHistoryMessageRef(message: message)],
                               labelsAdded: [GmailHistoryLabelChange(message: message, labelIds: ["STARRED"])])
        _ = GmailListThreadsResponse(threads: [], nextPageToken: nil)
        _ = GmailListMessagesResponse(messages: [message])
        _ = GmailListDraftsResponse(drafts: [])
        _ = GmailListHistoryResponse(history: [], historyId: "1")
        _ = GmailListLabelsResponse(labels: [])
        _ = GmailSendAs(sendAsEmail: "me@example.com", isPrimary: true)
        _ = GmailMessagePart(partId: "1", parts: [GmailMessagePart(mimeType: "text/html")])
        _ = GmailMessagePartBody(attachmentId: "a")
        #expect(GmailHistoryRecord(id: "2").messages == nil)
    }

    @Test func apiSurface() {
        var query = ListQuery()
        query.labelIDs = ["INBOX"]
        #expect(query.maxResults == 100 && !query.includeSpamTrash)
        #expect(standardMetadataHeaders.contains("X-OpenHuman-Origin"))
        #expect(MessageFormat.metadata.rawValue == "metadata")
        #expect(HistoryType.labelAdded.rawValue == "labelAdded")
        let item = BatchItemResult<GmailThread>(id: "t1", result: .failure(.notFound("t1")))
        if case .failure(let error) = item.result { #expect(error == .notFound("t1")) }
    }

    @Test func safeModeAndMetrics() {
        #expect(SafeMode.normal.oauthScopes == [GmailScope.modify])
        #expect(SafeMode.writeAllowlist.oauthScopes == [GmailScope.modify])
        #expect(SafeMode.readOnly.oauthScopes == [GmailScope.readonly])
        #expect(SafeMode.fromEnvironment(nil) == .readOnly)
        #expect(SafeMode.fromEnvironment("") == .readOnly)
        #expect(SafeMode.fromEnvironment("read-only") == .readOnly)
        #expect(SafeMode.fromEnvironment("write-allowlist") == .writeAllowlist)
        #expect(SafeMode.fromEnvironment("normal") == .normal)
        #expect(SafeMode.fromEnvironment("readonly") == .readOnly)
        #expect(SafeMode.fromEnvironment("Normal") == .readOnly)
        #expect(TransportError.blockedBySafeMode("POST /gmail/v1/users/me/messages/send") != .other("x"))
        let metric = GmailCallMetric(method: "messages.get", units: 5, status: 200, attempts: 1, durationMs: 12)
        struct Sink: GmailMetricsSink { func record(_ metric: GmailCallMetric) {} }
        Sink().record(metric)
        #expect(metric.units == 5)
    }

    @Test func mimeModel() {
        let field = MIMEHeaderField(name: "Subject", value: "Hi")
        let headers = MIMEHeaders(fields: [field, MIMEHeaderField(name: "received", value: "a"), MIMEHeaderField(name: "Received", value: "b")])
        #expect(headers["subject"] == "Hi")
        #expect(headers.values("RECEIVED") == ["a", "b"])
        let me = EmailAddress(email: "me@example.com")
        let parsed = ParsedMessage(headers: headers, subject: "Hi", from: me, to: [], cc: [], bcc: [], replyTo: [], references: [],
                                   attachments: [ParsedAttachment(partID: "2", filename: "a.pdf", mimeType: "application/pdf",
                                                                  size: 1, isInline: false)],
                                   calendarParts: [], warnings: [])
        #expect(parsed.htmlBody == nil)
        _ = GmailPayloadPart(headers: [field], parts: [GmailPayloadPart(mimeType: "text/plain", headers: [], data: "aGk", parts: [])])
        let outgoing = OutgoingMessage(from: me, to: [me], cc: [], bcc: [], replyTo: [], subject: "s", textBody: "t",
                                       attachments: [OutgoingAttachment(filename: "a", mimeType: "text/plain", data: Data(), isInline: false)],
                                       references: [], messageID: "<oh.x@example.com>", date: Date(timeIntervalSince1970: 0),
                                       extraHeaders: [MIMEHeaderField(name: "X-OpenHuman-Origin", value: "agent")])
        #expect(outgoing.extraHeaders.count == 1)
        #expect(MIMEError.tooLarge(bytes: 36_000_000) != .missingBody)
        let handling: [BccHandling] = [.includeForGmailSubmission, .strip]
        #expect(handling.count == 2)
        _ = ReplyContext(references: [], subject: "s", to: [], cc: [], replyTo: [], date: Date(), gmailThreadID: "t")
        let skeleton = ReplySkeleton(to: [me], cc: [], subject: "Re: s", references: [], quotedHTML: "", quotedText: "")
        #expect(skeleton.gmailThreadID == nil)
        let modes: [ReplyMode] = [.reply, .replyAll, .forward]
        #expect(modes.count == 3)
    }
}

extension RequestPriority {
    static var allSorted: [RequestPriority] { [.interactive, .backfill, .queue, .sync].sorted() }
}
