import Foundation
import OpenHumanCore

struct GmailCall: Sendable {
    var method: GmailMethod
    var httpMethod: String
    var url: URL
    var body: Data? = nil
    var contentType: String? = nil
    var priority: RequestPriority
    var timeout: Duration = .seconds(30)
    var accept: String = "application/json"
    var resource: String
}

struct RequestExecutor: Sendable {
    let transport: any HTTPTransport
    let tokens: any AccessTokenProvider
    let limiter: QuotaLimiter
    let clock: any OHClock
    let config: GmailClientConfig
    let metrics: (any GmailMetricsSink)?
    let jitter: @Sendable () -> Double

    func execute(_ call: GmailCall) async throws -> HTTPResponse {
        let policy = call.priority == .interactive ? config.retryInteractive : config.retryBackground
        let started = clock.now
        var httpAttempts = 0
        var policyAttempts = 0
        var units = 0
        var lastStatus: Int?
        var forceRefresh = false
        var refreshUsed = false
        func finish(_ status: Int?) {
            let ms = Int((clock.now.timeIntervalSince(started) * 1000).rounded())
            metrics?.record(GmailCallMetric(method: call.method.rawValue, units: units, status: status,
                                            attempts: max(httpAttempts, 1), durationMs: max(0, ms)))
        }
        while true {
            if Task.isCancelled { finish(lastStatus); throw GmailError.cancelled }
            httpAttempts += 1
            policyAttempts += 1
            let result = await attempt(call, cost: QuotaCost.units(call.method), forceRefresh: forceRefresh)
            forceRefresh = false
            units += result.units
            lastStatus = result.status
            let failure: GmailError
            switch result.outcome {
            case .success(let response):
                finish(response.status)
                return response
            case .failure(let error):
                failure = error
            }
            if failure == .unauthorized, !refreshUsed, result.status == 401 {
                refreshUsed = true
                forceRefresh = true
                policyAttempts -= 1
                continue
            }
            if case .rateLimited(let retryAfter) = failure {
                await limiter.noteRateLimited(retryAfter: retryAfter)
                if let retryAfter, retryAfter > policy.maxRetryAfter {
                    finish(lastStatus)
                    throw failure
                }
            }
            guard RetryRules.isRetryable(failure, idempotent: call.method.isIdempotent),
                  policyAttempts < policy.maxAttempts else {
                finish(lastStatus)
                throw failure
            }
            var retryAfter: Duration?
            if case .rateLimited(let after) = failure { retryAfter = after }
            let wait = policy.delay(beforeRetry: policyAttempts, retryAfter: retryAfter, jitter: jitter())
            Log(.gmail).info("\(call.method.rawValue) attempt \(httpAttempts) failed (\(Self.code(failure))); retrying")
            do {
                try await clock.sleep(for: wait)
            } catch {
                finish(lastStatus)
                throw GmailError.cancelled
            }
        }
    }

    struct AttemptResult {
        var outcome: Result<HTTPResponse, GmailError>
        var status: Int?
        var units: Int
    }

    func attempt(_ call: GmailCall, cost: Int, forceRefresh: Bool) async -> AttemptResult {
        do {
            try await limiter.acquire(units: cost, priority: call.priority)
        } catch {
            return AttemptResult(outcome: .failure(.cancelled), status: nil, units: 0)
        }
        let result = await send(call, cost: cost, forceRefresh: forceRefresh)
        await limiter.release()
        return result
    }

    private func send(_ call: GmailCall, cost: Int, forceRefresh: Bool) async -> AttemptResult {
        let token: String
        do {
            token = try await tokens.accessToken(forceRefresh: forceRefresh)
        } catch {
            return AttemptResult(outcome: .failure(Self.mapTokenError(error)), status: nil, units: 0)
        }
        var headers = ["Authorization": "Bearer \(token)", "Accept": call.accept]
        if let contentType = call.contentType { headers["Content-Type"] = contentType }
        let request = HTTPRequest(method: call.httpMethod, url: call.url, headers: headers, body: call.body,
                                  timeout: call.timeout)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as TransportError {
            switch error {
            case .cancelled:
                return AttemptResult(outcome: .failure(.cancelled), status: nil, units: 0)
            case .refusedByGuard:
                return AttemptResult(outcome: .failure(.transport(error)), status: nil, units: 0)
            default:
                return AttemptResult(outcome: .failure(.transport(error)), status: nil, units: cost)
            }
        } catch is CancellationError {
            return AttemptResult(outcome: .failure(.cancelled), status: nil, units: 0)
        } catch {
            return AttemptResult(outcome: .failure(.transport(.other(String(describing: type(of: error))))),
                                 status: nil, units: cost)
        }
        if (200..<300).contains(response.status) {
            return AttemptResult(outcome: .success(response), status: response.status, units: cost)
        }
        let error = GmailErrorMapping.error(status: response.status, headers: response.headers, body: response.body,
                                            resource: call.resource, now: clock.now)
        return AttemptResult(outcome: .failure(error), status: response.status, units: cost)
    }

    static func mapTokenError(_ error: Error) -> GmailError {
        switch error {
        case OAuthError.reauthRequired: return .reauthRequired
        case OAuthError.cancelled: return .cancelled
        case OAuthError.tokenEndpoint(let status, _, _) where status >= 500: return .server(status: status, message: nil)
        case let t as TransportError: return t == .cancelled ? .cancelled : .transport(t)
        case is CancellationError: return .cancelled
        default: return .unauthorized
        }
    }

    static func code(_ error: GmailError) -> String {
        switch error {
        case .unauthorized: return "unauthorized"
        case .reauthRequired: return "reauth_required"
        case .forbidden(let reason, _): return "forbidden:\(reason)"
        case .notFound: return "not_found"
        case .historyExpired: return "history_expired"
        case .rateLimited: return "rate_limited"
        case .dailyLimitExceeded: return "daily_limit"
        case .badRequest(let reason, _): return "bad_request:\(reason ?? "-")"
        case .preconditionFailed: return "precondition_failed"
        case .payloadTooLarge: return "payload_too_large"
        case .server(let status, _): return "server_\(status)"
        case .transport(let t):
            switch t {
            case .timedOut: return "transport:timed_out"
            case .notConnected: return "transport:not_connected"
            case .connectionLost: return "transport:connection_lost"
            case .cannotConnect: return "transport:cannot_connect"
            case .tls: return "transport:tls"
            case .cancelled: return "transport:cancelled"
            case .other: return "transport:other"
            case .refusedByGuard: return "refused_by_guard"
            }
        case .decoding: return "decoding"
        case .cancelled: return "cancelled"
        case .quotaBudgetExhausted: return "quota_budget_exhausted"
        }
    }
}

extension GmailError {
    public var code: String { RequestExecutor.code(self) }
}
