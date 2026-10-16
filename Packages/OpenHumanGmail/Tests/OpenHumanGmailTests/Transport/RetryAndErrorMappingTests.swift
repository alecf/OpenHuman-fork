import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct RetryAndErrorMappingTests {
    private func body(_ reason: String?, status: String? = nil, message: String = "msg") -> Data {
        var inner: [String: Any] = ["code": 0, "message": message]
        if let status { inner["status"] = status }
        if let reason { inner["errors"] = [["reason": reason, "domain": "global"]] }
        return try! JSONSerialization.data(withJSONObject: ["error": inner])
    }

    @Test func statusMappingTable() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let table: [(Int, String?, [String: String], GmailError)] = [
            (400, "invalidArgument", [:], .badRequest(reason: "invalidArgument", message: "msg")),
            (401, "authError", [:], .unauthorized),
            (403, "rateLimitExceeded", ["retry-after": "7"], .rateLimited(retryAfter: .seconds(7))),
            (403, "userRateLimitExceeded", [:], .rateLimited(retryAfter: nil)),
            (403, "dailyLimitExceeded", [:], .dailyLimitExceeded),
            (403, "insufficientPermissions", [:], .forbidden(reason: "insufficientPermissions", message: "msg")),
            (404, "notFound", [:], .notFound("threads/t1")),
            (409, "duplicate", [:], .badRequest(reason: "conflict", message: "msg")),
            (412, nil, [:], .preconditionFailed("msg")),
            (413, nil, [:], .payloadTooLarge),
            (429, "rateLimitExceeded", ["retry-after": "30"], .rateLimited(retryAfter: .seconds(30))),
            (500, "backendError", [:], .server(status: 500, message: "msg")),
            (503, nil, [:], .server(status: 503, message: "msg")),
        ]
        for (status, reason, headers, expected) in table {
            let got = GmailErrorMapping.error(status: status, headers: headers, body: body(reason), resource: "threads/t1",
                                              now: now)
            #expect(got == expected, "\(status) \(reason ?? "-")")
        }
        #expect(GmailErrorMapping.error(status: 403, headers: [:], body: body(nil, status: "PERMISSION_DENIED"),
                                        resource: "x", now: now) == .forbidden(reason: "PERMISSION_DENIED", message: "msg"))
        #expect(GmailErrorMapping.error(status: 502, headers: [:], body: Data("<html>".utf8), resource: "x", now: now)
                == .server(status: 502, message: nil))
    }

    @Test func retryMatrix() {
        let cases: [(GmailError, Bool, Bool)] = [
            (.rateLimited(retryAfter: nil), true, true), (.rateLimited(retryAfter: nil), false, true),
            (.server(status: 503, message: nil), true, true), (.server(status: 503, message: nil), false, false),
            (.transport(.timedOut), true, true), (.transport(.timedOut), false, false),
            (.transport(.connectionLost(requestMayHaveBeenSent: true)), false, false),
            (.transport(.cannotConnect), false, true), (.transport(.notConnected), false, true),
            (.transport(.refusedByGuard("POST /x")), true, false),
            (.transport(.tls("x")), true, false),
            (.badRequest(reason: nil, message: ""), true, false), (.notFound("x"), true, false),
            (.forbidden(reason: "x", message: ""), true, false), (.dailyLimitExceeded, true, false),
        ]
        for (error, idempotent, retryable) in cases {
            #expect(RetryRules.isRetryable(error, idempotent: idempotent) == retryable, "\(error) \(idempotent)")
        }
        #expect(!GmailMethod.sendDraft.isIdempotent && !GmailMethod.sendMessage.isIdempotent
                && !GmailMethod.createDraft.isIdempotent)
        #expect(GmailMethod.getThread.isIdempotent && GmailMethod.batchModify.isIdempotent
                && GmailMethod.updateDraft.isIdempotent)
    }

    @Test func backoffIsExponentialPlusUpToOneSecondOfJitterAndRetryAfterFloor() {
        let p = RetryPolicy.background
        #expect((1...8).map { p.delay(beforeRetry: $0, retryAfter: nil, jitter: 1) }
                == [2, 3, 5, 9, 17, 33, 64, 64].map { Duration.seconds($0) })
        #expect((1...3).map { p.delay(beforeRetry: $0, retryAfter: nil, jitter: 0) } == [1, 2, 4].map { Duration.seconds($0) },
                "never sooner than the backoff")
        #expect(p.delay(beforeRetry: 3, retryAfter: nil, jitter: 0.5) == .milliseconds(4_500))
        #expect(p.delay(beforeRetry: 1, retryAfter: .seconds(20), jitter: 1) == .seconds(20))
    }

    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_792_560_000)
        #expect(RetryAfter.parse("120", now: now) == .seconds(120))
        #expect(RetryAfter.parse(" 0 ", now: now) == .zero)
        #expect(RetryAfter.parse("Wed, 21 Oct 2026 07:28:00 GMT", now: now) == .seconds(7_680))
        #expect(RetryAfter.parse("Wednesday, 21-Oct-26 07:28:00 GMT", now: now) == .seconds(7_680))
        #expect(RetryAfter.parse("Wed Oct 21 07:28:00 2026", now: now) == .seconds(7_680))
        #expect(RetryAfter.parse("Tue, 20 Oct 2026 07:28:00 GMT", now: now) == .zero)
        #expect(RetryAfter.parse("soon", now: now) == nil)
        #expect(RetryAfter.parse("", now: now) == nil)
        #expect(RetryAfter.parse("-5", now: now) == nil)
    }

    @Test func quotaCostTable() {
        let google: [GmailMethod: Int] = [
            .getProfile: 1, .listSendAs: 1, .listLabels: 1, .getLabel: 1, .createLabel: 5,
            .listThreads: 10, .getThread: 40, .trashThread: 20, .untrashThread: 10,
            .listMessages: 5, .getMessage: 20, .getAttachment: 20, .batchModify: 50, .modifyMessage: 5,
            .trashMessage: 20, .untrashMessage: 5, .sendMessage: 100, .insertMessage: 25,
            .listDrafts: 5, .getDraft: 20, .createDraft: 10, .updateDraft: 15, .deleteDraft: 10, .sendDraft: 100,
            .listHistory: 2,
        ]
        for method in GmailMethod.allCases {
            #expect(QuotaCost.units(method) == google[method], "\(method.rawValue)")
        }
        #expect(google.count == GmailMethod.allCases.count)
        #expect(GmailError.server(status: 503, message: "x").code == "server_503")
        #expect(GmailError.transport(.refusedByGuard("POST /gmail/v1/users/me/settings/sendAs/a@b")).code
                == "refused_by_guard")
    }
}
