import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct RequestExecutorTests {
    struct Harness {
        let http = FakeHTTPTransport()
        let tokens = StaticTokenProvider()
        let clock = InstantClock()
        let metrics = RecordingMetricsSink()
        func client(transport: (any HTTPTransport)? = nil, config: GmailClientConfig? = nil) -> GmailClient {
            let config = config ?? GmailClientConfig(userAgent: "OpenHumanMail/test")
            return GmailClient(accountEmail: "me@example.com", tokens: tokens, transport: transport ?? http,
                               config: config, clock: clock, metrics: metrics,
                               limiter: QuotaLimiter(unitsPerMinute: 100_000, maxConcurrent: 8, clock: clock),
                               jitter: { 1.0 })
        }
    }

    static let profile = ["emailAddress": "me@example.com", "historyId": "1234"]

    private func errorBody(_ status: Int, _ reason: String) -> [String: Any] {
        ["error": ["code": status, "message": "synthetic", "errors": [["reason": reason]]]]
    }

    @Test func successSendsBearerTokenAndRecordsOneMetric() async throws {
        let h = Harness()
        h.http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(200, Self.profile) }
        let profile = try await h.client().getProfile(priority: .interactive)
        #expect(profile.historyId == "1234")
        #expect(h.http.requests.first?.headers["Authorization"] == "Bearer test-access-token")
        #expect(h.metrics.metrics == [GmailCallMetric(method: "getProfile", units: 1, status: 200, attempts: 1, durationMs: 0)])
    }

    @Test func serverErrorsRetryWithBackoffThenSurface() async throws {
        let h = Harness()
        h.http.on("GET", "/gmail/v1/users/me/labels") { _ in FakeHTTPTransport.json(503, self.errorBody(503, "backendError")) }
        await #expect(throws: GmailError.server(status: 503, message: "synthetic")) { _ = try await h.client().listLabels() }
        #expect(h.http.requests.count == 6)
        #expect(h.clock.sleeps.filter { $0 > 0 } == [2, 3, 5, 9, 17])
        #expect(h.metrics.metrics.count == 1)
        #expect(h.metrics.metrics.first?.attempts == 6 && h.metrics.metrics.first?.units == 6)
        #expect(h.metrics.metrics.first?.status == 503)
    }

    @Test func interactiveGivesUpAfterThreeAttempts() async throws {
        let h = Harness()
        h.http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(500, [:]) }
        await #expect(throws: GmailError.self) { _ = try await h.client().getProfile(priority: .interactive) }
        #expect(h.http.requests.count == 3)
    }

    @Test func recoversAfterTransientFailures() async throws {
        let h = Harness()
        h.http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(200, Self.profile) }
        h.http.failNext(.timedOut)
        h.http.failNext(.connectionLost(requestMayHaveBeenSent: true))
        _ = try await h.client().getProfile(priority: .sync)
        #expect(h.http.requests.count == 3)
        #expect(h.metrics.metrics.first?.attempts == 3)
    }

    @Test func nonIdempotentCallsAreNotRetriedOnAmbiguousFailures() async throws {
        let h = Harness()
        h.http.on("POST", "/gmail/v1/users/me/drafts/send") { _ in FakeHTTPTransport.json(503, [:]) }
        await #expect(throws: GmailError.server(status: 503, message: nil)) { _ = try await h.client().sendDraft(id: "r1") }
        #expect(h.http.requests.count == 1)

        let h2 = Harness()
        h2.http.failNext(.timedOut)
        await #expect(throws: GmailError.transport(.timedOut)) { _ = try await h2.client().sendDraft(id: "r1") }
        #expect(h2.http.requests.count == 1)

        let h3 = Harness()
        h3.http.on("POST", "/gmail/v1/users/me/drafts/send") { _ in FakeHTTPTransport.json(200, ["id": "m9"]) }
        h3.http.failNext(.cannotConnect)
        _ = try await h3.client().sendDraft(id: "r1")
        #expect(h3.http.requests.count == 2)
    }

    @Test func rateLimitHonorsRetryAfterAndSurfacesLongWaits() async throws {
        let h = Harness()
        let count = Counter()
        h.http.on("GET", "/gmail/v1/users/me/profile") { _ in
            count.increment() == 1
                ? FakeHTTPTransport.json(429, self.errorBody(429, "rateLimitExceeded"), headers: ["retry-after": "45"])
                : FakeHTTPTransport.json(200, Self.profile)
        }
        _ = try await h.client().getProfile(priority: .sync)
        #expect(h.clock.sleeps.contains(45))

        let h2 = Harness()
        h2.http.on("GET", "/gmail/v1/users/me/profile") { _ in
            FakeHTTPTransport.json(429, self.errorBody(429, "rateLimitExceeded"), headers: ["retry-after": "900"])
        }
        await #expect(throws: GmailError.rateLimited(retryAfter: .seconds(900))) {
            _ = try await h2.client().getProfile(priority: .sync)
        }
        #expect(h2.http.requests.count == 1)
    }

    @Test func unauthorizedForcesOneRefreshThenRetriesOnce() async throws {
        let h = Harness()
        let count = Counter()
        h.http.on("GET", "/gmail/v1/users/me/profile") { _ in
            count.increment() == 1 ? FakeHTTPTransport.json(401, self.errorBody(401, "authError"))
                                   : FakeHTTPTransport.json(200, Self.profile)
        }
        _ = try await h.client().getProfile(priority: .sync)
        #expect(h.tokens.forcedRefreshes == 1 && h.http.requests.count == 2)

        let h2 = Harness()
        h2.http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(401, self.errorBody(401, "authError")) }
        await #expect(throws: GmailError.unauthorized) { _ = try await h2.client().getProfile(priority: .sync) }
        #expect(h2.tokens.forcedRefreshes == 1 && h2.http.requests.count == 2)
    }

    @Test func reauthRequiredFromTheTokenProviderIsNotRetried() async throws {
        let h = Harness()
        h.tokens.setFailure(OAuthError.reauthRequired)
        await #expect(throws: GmailError.reauthRequired) { _ = try await h.client().getProfile(priority: .sync) }
        #expect(h.http.requests.isEmpty)
    }

    @Test func aGuardRefusalIsNeverRetriedAndCostsNothing() async throws {
        let h = Harness()
        let client = h.client(transport: ReadOnlyTransport(wrapping: h.http))
        await #expect(throws: GmailError.transport(.refusedByGuard("POST /gmail/v1/users/me/messages/batchModify"))) {
            try await client.batchModifyMessages(ids: ["m1"], add: [], remove: ["INBOX"])
        }
        #expect(h.http.requests.isEmpty)
        #expect(h.metrics.metrics.first?.units == 0 && h.metrics.metrics.first?.attempts == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func cancellationDuringBackoffSurfacesCancelled() async throws {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/profile") { _ in FakeHTTPTransport.json(503, [:]) }
        let clock = TestClock()
        let client = GmailClient(accountEmail: "me@example.com", tokens: StaticTokenProvider(), transport: http,
                                 config: GmailClientConfig(userAgent: "t"), clock: clock, metrics: nil,
                                 limiter: QuotaLimiter(unitsPerMinute: 6000, maxConcurrent: 8, clock: clock),
                                 jitter: { 1.0 })
        let task = Task { try await client.getProfile(priority: .sync) }
        for _ in 0..<60_000 where clock.sleeperCount == 0 { try await Task.sleep(for: .milliseconds(2)) } // flake-ok: waits for backoff registration before cancellation
        #expect(clock.sleeperCount == 1)
        task.cancel()
        await #expect(throws: GmailError.cancelled) { _ = try await task.value }
        #expect(http.requests.count == 1)
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    @discardableResult func increment() -> Int { value.withLock { $0 += 1; return $0 } }
    var current: Int { value.withLock { $0 } }
}
