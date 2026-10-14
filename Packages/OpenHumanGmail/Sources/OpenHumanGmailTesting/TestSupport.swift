import Foundation
import OpenHumanCore
import OpenHumanGmail
import Synchronization

public final class InstantClock: OHClock {
    private struct State { var now: Date; var sleeps: [TimeInterval] = [] }
    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date { state.withLock { $0.now } }

    public var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }

    public func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        state.withLock { s in
            s.sleeps.append(max(0, deadline.timeIntervalSince(s.now)))
            if deadline > s.now { s.now = deadline }
        }
        await Task.yield()
        try Task.checkCancellation()
    }

    public func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.addingTimeInterval(duration.timeInterval) }
    }
}

public final class StaticTokenProvider: AccessTokenProvider {
    private struct State { var calls = 0; var forced = 0; var failure: (any Error)?; var token: String }
    private let state: Mutex<State>

    public init(token: String = "test-access-token", failure: (any Error)? = nil) {
        state = Mutex(State(failure: failure, token: token))
    }

    public var calls: Int { state.withLock { $0.calls } }
    public var forcedRefreshes: Int { state.withLock { $0.forced } }
    public func setToken(_ token: String) { state.withLock { $0.token = token } }
    public func setFailure(_ error: (any Error)?) { state.withLock { $0.failure = error } }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        try state.withLock { s in
            s.calls += 1
            if forceRefresh { s.forced += 1 }
            if let failure = s.failure { throw failure }
            return s.token
        }
    }
}

public final class RecordingMetricsSink: GmailMetricsSink {
    private let log = Mutex<[GmailCallMetric]>([])
    public init() {}
    public func record(_ metric: GmailCallMetric) { log.withLock { $0.append(metric) } }
    public var metrics: [GmailCallMetric] { log.withLock { $0 } }
    public var totalUnits: Int { metrics.reduce(0) { $0 + $1.units } }
}

public final class FakeHTTPTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    private struct Route { var method: String; var pathPrefix: String; var handler: Handler }
    private struct State {
        var routes: [Route] = []
        var requests: [HTTPRequest] = []
        var injected: [TransportError] = []
        var inFlight = 0
        var maxInFlight = 0
    }
    private let state = Mutex(State())

    public init() {}

    public func on(_ method: String, _ pathPrefix: String, _ handler: @escaping Handler) {
        state.withLock { $0.routes.append(Route(method: method, pathPrefix: pathPrefix, handler: handler)) }
    }

    public func failNext(_ error: TransportError, count: Int = 1) {
        state.withLock { $0.injected += Array(repeating: error, count: count) }
    }

    public var requests: [HTTPRequest] { state.withLock { $0.requests } }
    public var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let (injected, handler): (TransportError?, Handler?) = state.withLock { s in
            s.requests.append(request)
            if !s.injected.isEmpty { return (s.injected.removeFirst(), nil) }
            let path = request.url.path(percentEncoded: false)
            let route = s.routes.last { $0.method == request.method && path.hasPrefix($0.pathPrefix) }
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return (nil, route?.handler)
        }
        if let injected { throw injected }
        defer { state.withLock { $0.inFlight -= 1 } }
        guard let handler else { return Self.json(404, ["error": ["code": 404, "message": "no route", "status": "NOT_FOUND"]]) }
        return try await handler(request)
    }

    public static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: headers.merging(["content-type": "application/json"]) { a, _ in a },
                            body: body)
    }

    public static func json<T: Encodable>(_ status: Int, encoding value: T) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"],
                     body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
}
