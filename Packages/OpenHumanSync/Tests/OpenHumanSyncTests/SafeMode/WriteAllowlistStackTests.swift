import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

// FakeGmailTransport cannot parse the messages.insert media upload yet, so this wire handles it
private final class InsertAwareWire: HTTPTransport {
    let rest: FakeGmailTransport
    private let log = Mutex<[HTTPRequest]>([])
    init(_ gmail: FakeGmail) { rest = FakeGmailTransport(gmail) }
    var requests: [HTTPRequest] { log.withLock { $0 } }
    var nonGETRequests: [HTTPRequest] { requests.filter { $0.method != "GET" && !$0.url.path().hasPrefix("/batch/") } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        guard request.method == "POST", request.url.path() == "/upload/gmail/v1/users/me/messages" else {
            return try await rest.send(request)
        }
        guard let contentType = request.headers["Content-Type"],
              let boundary = contentType.components(separatedBy: "boundary=").last, let body = request.body else {
            return HTTPResponse(status: 400, headers: [:], body: Data())
        }
        let open = Data("--\(boundary)\r\n".utf8), separator = Data("\r\n--\(boundary)\r\n".utf8)
        let close = Data("\r\n--\(boundary)--".utf8), blank = Data("\r\n\r\n".utf8)
        guard let s = body.range(of: separator), let c = body.range(of: close),
              let metaStart = body.range(of: blank, in: open.count..<s.lowerBound),
              let rawStart = body.range(of: blank, in: s.upperBound..<c.lowerBound) else {
            return HTTPResponse(status: 400, headers: [:], body: Data())
        }
        struct Meta: Decodable { var labelIds: [String] }
        let meta = try JSONDecoder().decode(Meta.self, from: body[metaStart.upperBound..<s.lowerBound])
        let message = try await rest.gmail.insertMessage(rawRFC822: Data(body[rawStart.upperBound..<c.lowerBound]),
                                                         labelIDs: meta.labelIds)
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"],
                            body: try JSONEncoder().encode(message))
    }
}

@Suite struct WriteAllowlistStackTests {
    @Test func syncAndHarnessThroughWriteGuardTouchOnlySyntheticThreads() async throws {
        let clock = InstantClock(now: testNow)
        var wireBox: InsertAwareWire?
        var clientBox: GmailClient?
        let allowlist = WriteAllowlistStore(accountEmail: "me@example.com")
        let h = try SyncHarness(clock: clock, onDisk: true) { gmail in
            let wire = InsertAwareWire(gmail)
            let transport = SafeModeTransport.wrap(wire, mode: .writeAllowlist, grantedScopes: [GmailScope.modify],
                                                   allowlist: allowlist)
            let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: transport,
                                     config: GmailClientConfig(userAgent: "OpenHumanMail/test"), clock: clock,
                                     metrics: nil)
            wireBox = wire
            clientBox = client
            return client
        }
        let wire = try #require(wireBox), client = try #require(clientBox)

        let real = await h.gmail.seedInbox(count: 5)
        let harness = try SyntheticThreads(api: client, runID: "20260921T1413Z-0001")
        let synthetic = try await harness.insertThreads(count: 3, date: testNow)
        try await h.syncer.sync(reason: "launch")
        #expect(Set(try h.inbox()) == Set(real + synthetic.map(\.threadID)))
        let writesAfterInsert = wire.nonGETRequests.count
        #expect(writesAfterInsert == 4)

        try await client.batchModifyMessages(ids: [synthetic[0].messageID], add: [], remove: ["INBOX"])
        await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /gmail/v1/users/me/messages/batchModify"))) {
            try await client.batchModifyMessages(ids: [real[0]], add: [], remove: ["INBOX"])
        }
        await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /gmail/v1/users/me/messages/batchModify"))) {
            try await client.batchModifyMessages(ids: [synthetic[1].messageID, real[1]], add: [], remove: ["INBOX"])
        }
        await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /upload/gmail/v1/users/me/messages/send"))) {
            _ = try await client.sendMessage(rawRFC822: Data("Subject: x\r\n\r\ny".utf8), threadID: synthetic[2].threadID)
        }
        #expect(wire.nonGETRequests.count == writesAfterInsert + 1)
        #expect(await h.gmail.labelIDs(ofMessage: real[0])?.contains("INBOX") == true)

        try await h.syncer.sync(reason: "poll")
        #expect(!(try h.inbox()).contains(synthetic[0].threadID))
        #expect(wire.nonGETRequests.count == writesAfterInsert + 1)
        let snapshot = try await GroundTruth.snapshot(api: client, sampleThreads: 50, now: testNow)
        let report = try GroundTruthCheck.compare(store: h.store, account: h.account, snapshot: snapshot, now: testNow)
        #expect(report.isClean, "\(report)")
        #expect(wire.nonGETRequests.count == writesAfterInsert + 1)

        let own = await allowlist.snapshot
        for request in wire.nonGETRequests {
            let path = request.url.path()
            let text = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            for id in real { #expect(!path.contains(id) && !text.contains("\"\(id)\""), "\(request.method) \(path)") }
        }
        #expect(own.threadIDs == Set(synthetic.map(\.threadID)))
    }
}
