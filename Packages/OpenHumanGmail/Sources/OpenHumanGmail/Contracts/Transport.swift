import Foundation
import OpenHumanCore

public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Duration = .seconds(30)

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
    // end generated-init
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    // end generated-init
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum TransportError: Error, Equatable, Sendable {
    case timedOut
    case notConnected
    case connectionLost(requestMayHaveBeenSent: Bool)
    case cannotConnect
    case tls(String)
    case cancelled
    case other(String)
    case refusedByGuard(String)
}

public enum GmailError: Error, Equatable, Sendable {
    case unauthorized
    case reauthRequired
    case forbidden(reason: String, message: String)
    case notFound(String)
    case historyExpired
    case rateLimited(retryAfter: Duration?)
    case dailyLimitExceeded
    case badRequest(reason: String?, message: String)
    case preconditionFailed(String)
    case payloadTooLarge
    case server(status: Int, message: String?)
    case transport(TransportError)
    case decoding(String)
    case cancelled
    case quotaBudgetExhausted
}

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var maxRetryAfter: Duration
    public static let background = RetryPolicy(maxAttempts: 6, baseDelay: .seconds(1), maxDelay: .seconds(64),
                                               maxRetryAfter: .seconds(300))
    public static let interactive = RetryPolicy(maxAttempts: 3, baseDelay: .seconds(1), maxDelay: .seconds(64),
                                                maxRetryAfter: .seconds(300))

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        maxAttempts: Int,
        baseDelay: Duration,
        maxDelay: Duration,
        maxRetryAfter: Duration
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
    }
    // end generated-init
}

public enum RequestPriority: Int, Sendable, Comparable {
    case backfill = 0, sync = 1, queue = 2, interactive = 3
    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GmailCallMetric: Sendable, Hashable {
    public var method: String
    public var units: Int
    public var status: Int?
    public var attempts: Int
    public var durationMs: Int

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        method: String,
        units: Int,
        status: Int? = nil,
        attempts: Int,
        durationMs: Int
    ) {
        self.method = method
        self.units = units
        self.status = status
        self.attempts = attempts
        self.durationMs = durationMs
    }
    // end generated-init
}

public protocol GmailMetricsSink: Sendable {
    func record(_ metric: GmailCallMetric)
}
