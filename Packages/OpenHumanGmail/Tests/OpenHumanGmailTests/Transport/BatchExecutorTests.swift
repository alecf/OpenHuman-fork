import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

final class BatchStub: Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var json: String }
    private struct State { var batches: [[String]] = []; var attempts: [String: Int] = [:]; var outer = 0 }
    private let state = Mutex(State())
    let answer: @Sendable (_ id: String, _ attempt: Int) -> Reply
    let outer: @Sendable (_ attempt: Int) -> HTTPResponse?

    init(outer: @escaping @Sendable (Int) -> HTTPResponse? = { _ in nil },
         answer: @escaping @Sendable (String, Int) -> Reply) {
        self.answer = answer
        self.outer = outer
    }

    var batches: [[String]] { state.withLock { $0.batches } }

    func install(on http: FakeHTTPTransport) {
        http.on("POST", "/batch/gmail/v1") { request in
            let outerAttempt = self.state.withLock { s -> Int in s.outer += 1; return s.outer }
            if let response = self.outer(outerAttempt) { return response }
            let text = String(decoding: request.body ?? Data(), as: UTF8.self)
            var out = ""
            var ids: [String] = []
            var contentID = ""
            for line in text.components(separatedBy: "\r\n") {
                if line.hasPrefix("Content-ID: ") { contentID = String(line.dropFirst("Content-ID: <".count).dropLast()) }
                guard line.hasPrefix("GET ") else { continue }
                let target = line.split(separator: " ")[1]
                let id = String(target.split(separator: "?")[0].split(separator: "/").last!)
                ids.append(id)
                let attempt = self.state.withLock { s -> Int in s.attempts[id, default: 0] += 1; return s.attempts[id]! }
                let reply = self.answer(id, attempt)
                out += "--resp\r\nContent-Type: application/http\r\nContent-ID: <response-\(contentID)>\r\n\r\n"
                out += "HTTP/1.1 \(reply.status) X\r\nContent-Type: application/json\r\n"
                for (k, v) in reply.headers { out += "\(k): \(v)\r\n" }
                out += "\r\n\(reply.json)\r\n"
            }
            out += "--resp--\r\n"
            self.state.withLock { $0.batches.append(ids) }
            return HTTPResponse(status: 200, headers: ["content-type": "multipart/mixed; boundary=resp"], body: Data(out.utf8))
        }
    }
}

@Suite struct BatchExecutorTests {
    struct Harness {
        let http = FakeHTTPTransport()
        let tokens = StaticTokenProvider()
        let clock = InstantClock()
        let metrics = RecordingMetricsSink()
        let limiter: QuotaLimiter
        init() { limiter = QuotaLimiter(unitsPerMinute: 1_000_000, maxConcurrent: 8, clock: clock) }
        func client(batchSize: Int = 25, transport: (any HTTPTransport)? = nil) -> GmailClient {
            GmailClient(accountEmail: "me@example.com", tokens: tokens, transport: transport ?? http,
                        config: GmailClientConfig(batchSize: batchSize, userAgent: "t"), clock: clock, metrics: metrics,
                        limiter: limiter, jitter: { 1.0 })
        }
    }

    static func ok(_ id: String) -> BatchStub.Reply { .init(status: 200, json: "{\"id\":\"\(id)\"}") }
    static let notFound = BatchStub.Reply(status: 404, json: "{\"error\":{\"code\":404,\"message\":\"gone\"}}")
    static func rateLimited(after: String? = nil) -> BatchStub.Reply {
        .init(status: 429, headers: after.map { ["Retry-After": $0] } ?? [:],
              json: "{\"error\":{\"code\":429,\"errors\":[{\"reason\":\"rateLimitExceeded\"}]}}")
    }
    func ids(_ n: Int) -> [String] { (0..<n).map { "m\($0)" } }

    @Test func oneBatchRequestInInputOrderWithBearerToken() async throws {
        let h = Harness()
        BatchStub { id, _ in Self.ok(id) }.install(on: h.http)
        let ids = ids(5)
        let results = try await h.client().getMessages(ids: ids, format: .metadata, metadataHeaders: ["From"], priority: .sync)
        #expect(results.map(\.id) == ids)
        for r in results { if case .success(let m) = r.result { #expect(m.id == r.id) } else { Issue.record("failed") } }
        #expect(h.http.requests.count == 1)
        let request = try #require(h.http.requests.first)
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/batch/gmail/v1")
        #expect(request.headers["Authorization"] == "Bearer test-access-token")
        #expect(request.headers["Content-Type"]?.hasPrefix("multipart/mixed; boundary=batch_") == true)
        let body = String(decoding: request.body ?? Data(), as: UTF8.self)
        #expect(body.contains("GET /gmail/v1/users/me/messages/m3?format=metadata&metadataHeaders=From HTTP/1.1"))
    }

    @Test func chunksByBatchSizeAndChargesInnerCosts() async throws {
        let h = Harness()
        let stub = BatchStub { id, _ in Self.ok(id) }
        stub.install(on: h.http)
        let results = try await h.client(batchSize: 25).getThreads(ids: ids(60), format: .minimal, metadataHeaders: [], priority: .sync)
        #expect(results.count == 60)
        #expect(stub.batches.map(\.count).sorted() == [10, 25, 25])
        #expect(Set(stub.batches.flatMap { $0 }) == Set(ids(60)))
        #expect(await h.limiter.unitsUsed(since: .distantPast) == 2_400)
        #expect(h.metrics.metrics.count == 60)
        #expect(h.metrics.totalUnits == 2_400)
        #expect(h.metrics.metrics.allSatisfy { $0.method == "threads.get" && $0.status == 200 && $0.attempts == 1 })
    }

    @Test func partialFailureIsPerItemAndNotRetriedWhenPermanent() async throws {
        let h = Harness()
        let stub = BatchStub { id, _ in id == "m1" ? Self.notFound : Self.ok(id) }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ids(3), format: .full, metadataHeaders: [], priority: .sync)
        #expect(stub.batches.count == 1)
        guard case .failure(let error) = results[1].result else { Issue.record("m1 should fail"); return }
        #expect(error == .notFound("messages/m1"))
        for index in [0, 2] { if case .failure = results[index].result { Issue.record("m\(index) should succeed") } }
        #expect(h.metrics.metrics.first { $0.status == 404 }?.attempts == 1)
    }

    @Test func retryableItemsAreRebatchedAloneWithBackoffAndRetryAfter() async throws {
        let h = Harness()
        let stub = BatchStub { id, attempt in
            switch (id, attempt) {
            case ("m1", 1): return Self.rateLimited(after: "7")
            case ("m2", 1), ("m2", 2): return .init(status: 503, json: "{\"error\":{\"code\":503}}")
            default: return Self.ok(id)
            }
        }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ids(4), format: .full, metadataHeaders: [], priority: .sync)
        #expect(stub.batches == [["m0", "m1", "m2", "m3"], ["m1", "m2"], ["m2"]])
        for r in results { if case .failure = r.result { Issue.record("\(r.id) should succeed after retries") } }
        #expect(h.clock.sleeps.filter { $0 > 0 } == [7, 3])
        #expect(h.metrics.metrics.count == 4)
        #expect(Set(h.metrics.metrics.map(\.attempts)) == [1, 2, 3])
        #expect(h.metrics.totalUnits == 20 * 4 + 20 * 2 + 20)
    }

    @Test func itemsThatNeverSucceedSurfaceTheirErrorAfterTheAttemptBudget() async throws {
        let h = Harness()
        let stub = BatchStub { id, _ in id == "m1" ? .init(status: 500, json: "{}") : Self.ok(id) }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ids(3), format: .full, metadataHeaders: [], priority: .interactive)
        #expect(stub.batches.count == 3)
        #expect(stub.batches.last == ["m1"])
        guard case .failure(let error) = results[1].result, case .server(500, _) = error else {
            Issue.record("expected server error"); return
        }
        #expect(h.metrics.metrics.first { $0.status == 500 }?.attempts == 3)
    }

    @Test func tooLongRetryAfterSurfacesRateLimitedForThatItem() async throws {
        let h = Harness()
        let stub = BatchStub { id, _ in id == "m0" ? Self.rateLimited(after: "900") : Self.ok(id) }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ids(2), format: .full, metadataHeaders: [], priority: .sync)
        #expect(stub.batches.count == 1)
        guard case .failure(let error) = results[0].result, case .rateLimited(let after) = error else {
            Issue.record("expected rateLimited"); return
        }
        #expect(after == .seconds(900))
    }

    @Test func missingItemsAreRetriedAsLostAndOutOfOrderPartsAreMatched() async throws {
        let h = Harness()
        let calls = Mutex(0)
        h.http.on("POST", "/batch/gmail/v1") { request in
            let n = calls.withLock { $0 += 1; return $0 }
            let ids = String(decoding: request.body ?? Data(), as: UTF8.self).components(separatedBy: "\r\n")
                .filter { $0.hasPrefix("GET ") }.map { String($0.split(separator: " ")[1].split(separator: "/").last!.split(separator: "?")[0]) }
            var out = ""
            for (position, id) in ids.enumerated().reversed() where !(n == 1 && position == ids.count - 1) {
                out += "--r\r\nContent-Type: application/http\r\nContent-ID: <response-item-\(position)>\r\n\r\nHTTP/1.1 200 OK\r\n\r\n{\"id\":\"\(id)\"}\r\n"
            }
            out += "--r--\r\n"
            return HTTPResponse(status: 200, headers: ["content-type": "multipart/mixed; boundary=r"], body: Data(out.utf8))
        }
        let results = try await h.client().getMessages(ids: ["a", "b", "c"], format: .full, metadataHeaders: [], priority: .sync)
        #expect(calls.withLock { $0 } == 2)
        for r in results { if case .success(let m) = r.result { #expect(m.id == r.id) } else { Issue.record("\(r.id) failed") } }
    }

    @Test func wholeBatchServerErrorIsRetriedThenSucceeds() async throws {
        let h = Harness()
        let stub = BatchStub(outer: { $0 <= 2 ? FakeHTTPTransport.json(503, ["error": ["code": 503]]) : nil }) { id, _ in Self.ok(id) }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ids(3), format: .full, metadataHeaders: [], priority: .sync)
        #expect(results.count == 3)
        #expect(h.http.requests.count == 3)
        #expect(h.clock.sleeps.filter { $0 > 0 } == [2, 3])
        #expect(h.metrics.metrics.allSatisfy { $0.attempts == 3 })
    }

    @Test func wholeBatchFailureThrowsAfterRetriesAndRecordsEveryItem() async throws {
        let h = Harness()
        BatchStub(outer: { _ in FakeHTTPTransport.json(500, [:]) }) { id, _ in Self.ok(id) }.install(on: h.http)
        await #expect(throws: GmailError.server(status: 500, message: nil)) {
            _ = try await h.client().getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .interactive)
        }
        #expect(h.http.requests.count == 3)
        #expect(h.metrics.metrics.count == 2 && h.metrics.metrics.allSatisfy { $0.status == 500 && $0.attempts == 3 })
    }

    @Test func outer401ForcesOneRefreshThenRetries() async throws {
        let h = Harness()
        BatchStub(outer: { $0 == 1 ? FakeHTTPTransport.json(401, ["error": ["code": 401]]) : nil }) { id, _ in Self.ok(id) }
            .install(on: h.http)
        let results = try await h.client().getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .sync)
        #expect(results.count == 2)
        #expect(h.tokens.forcedRefreshes == 1)
        #expect(h.http.requests.count == 2)
        #expect(h.clock.sleeps.filter { $0 > 0 }.isEmpty)
    }

    @Test func persistent401ThrowsUnauthorizedAfterOneRefresh() async throws {
        let h = Harness()
        BatchStub(outer: { _ in FakeHTTPTransport.json(401, ["error": ["code": 401]]) }) { id, _ in Self.ok(id) }.install(on: h.http)
        await #expect(throws: GmailError.unauthorized) {
            _ = try await h.client().getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .sync)
        }
        #expect(h.tokens.forcedRefreshes == 1 && h.http.requests.count == 2)
    }

    @Test func inner401ItemsRefreshOnceAndRetryOnlyThoseItems() async throws {
        let h = Harness()
        let stub = BatchStub { id, attempt in
            id == "b" && attempt == 1 ? .init(status: 401, json: "{\"error\":{\"code\":401}}") : Self.ok(id)
        }
        stub.install(on: h.http)
        let results = try await h.client().getMessages(ids: ["a", "b", "c"], format: .full, metadataHeaders: [], priority: .sync)
        #expect(stub.batches == [["a", "b", "c"], ["b"]])
        #expect(h.tokens.forcedRefreshes == 1)
        for r in results { if case .failure = r.result { Issue.record("\(r.id) failed") } }
    }

    @Test func aBatchOutsideTheTransportIsRefusedBySafeModeOnlyWhenNotAllGETs() async throws {
        let h = Harness()
        BatchStub { id, _ in Self.ok(id) }.install(on: h.http)
        let readOnly = ReadOnlyTransport(wrapping: h.http)
        let results = try await h.client(transport: readOnly).getMessages(ids: ids(3), format: .full, metadataHeaders: [], priority: .sync)
        #expect(results.count == 3 && h.http.requests.count == 1)
        let blocked = ReadOnlyTransport(wrapping: FakeHTTPTransport())
        let request = HTTPRequest(method: "POST", url: BatchCodec.endpoint,
                                  headers: ["Content-Type": "multipart/mixed; boundary=b"],
                                  body: Data("--b\r\nContent-Type: application/http\r\n\r\nPOST /gmail/v1/users/me/messages/x/trash HTTP/1.1\r\n\r\n--b--\r\n".utf8))
        await #expect(throws: TransportError.blockedBySafeMode("POST /batch/gmail/v1")) { _ = try await blocked.send(request) }
    }

    @Test func safeModeRefusalOfTheWholeBatchIsNotRetried() async throws {
        let h = Harness()
        struct Refusing: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw TransportError.blockedBySafeMode("POST /batch/gmail/v1") }
        }
        await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /batch/gmail/v1"))) {
            _ = try await h.client(transport: Refusing()).getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .sync)
        }
        #expect(h.metrics.totalUnits == 0 && h.clock.sleeps.isEmpty)
    }

    @Test func batchSizeOneAndSingleIDsUseIndividualGETs() async throws {
        let h = Harness()
        h.http.on("GET", "/gmail/v1/users/me/messages/") { r in FakeHTTPTransport.json(200, ["id": r.url.lastPathComponent]) }
        _ = try await h.client(batchSize: 1).getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .sync)
        _ = try await h.client().getMessages(ids: ["c"], format: .full, metadataHeaders: [], priority: .sync)
        #expect(h.http.requests.count == 3 && h.http.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func cancellationStopsTheBatchWithoutAResult() async throws {
        let h = Harness()
        let started = Mutex(false)
        h.http.on("POST", "/batch/gmail/v1") { _ in
            started.withLock { $0 = true }
            try await Task.sleep(for: .seconds(60))
            return FakeHTTPTransport.json(200, [:])
        }
        let client = h.client()
        let task = Task { try await client.getMessages(ids: ["a", "b"], format: .full, metadataHeaders: [], priority: .sync) }
        while !started.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        await #expect(throws: GmailError.cancelled) { _ = try await task.value }
    }
}

@Suite struct BatchRetryReasonTests {
    @Test func reasonsAreClassifiedAndCountedWithTheirStatuses() {
        let failures: [(error: GmailError, status: Int?)] = [
            (.rateLimited(retryAfter: nil), 429), (.rateLimited(retryAfter: nil), 429), (.rateLimited(retryAfter: nil), 403),
            (.server(status: 503, message: nil), 503), (.transport(.connectionLost(requestMayHaveBeenSent: true)), nil),
            (.transport(.timedOut), nil),
        ]
        #expect(BatchRetryReason.summary(failures, wholeBatch: false)
            == "rate limit 3 (403, 429 x2), server 1 (503), transport 1, missing part 1")
        #expect(BatchRetryReason.summary([(.server(status: 500, message: nil), 500)], wholeBatch: true)
            == "server 1 (500), whole batch")
        #expect(BatchRetryReason.summary([(.transport(.connectionLost(requestMayHaveBeenSent: true)), nil)], wholeBatch: true)
            == "transport 1, whole batch")
        #expect(BatchRetryReason.summary([], wholeBatch: false) == "unknown")
        #expect(BatchRetryReason.classify(.unauthorized, status: 401) == .auth)
        #expect(BatchRetryReason.seconds(.milliseconds(1_400)) == "1.4 s")
    }

    @Test func aRetryResendsOnlyTheItemsThatFailedWhateverTheMix() async throws {
        let h = BatchExecutorTests.Harness()
        let stub = BatchStub { id, attempt in
            switch (id, attempt) {
            case ("m1", 1): return BatchExecutorTests.rateLimited(after: "2")
            case ("m3", 1): return .init(status: 503, json: "{\"error\":{\"code\":503}}")
            case ("m5", 1): return .init(status: 500, json: "{\"error\":{\"code\":500}}")
            default: return BatchExecutorTests.ok(id)
            }
        }
        stub.install(on: h.http)
        let ids = (0..<8).map { "m\($0)" }
        let results = try await h.client().getMessages(ids: ids, format: .full, metadataHeaders: [], priority: .sync)
        #expect(stub.batches == [ids, ["m1", "m3", "m5"]], "succeeded items are never fetched twice")
        #expect(results.allSatisfy { if case .success = $0.result { true } else { false } })
        #expect(h.metrics.totalUnits == 20 * 8 + 20 * 3)
    }
}
