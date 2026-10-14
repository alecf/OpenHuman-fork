import Foundation
import Network
import OpenHumanCore
import OpenHumanGmail
import Synchronization

public final class NWLoopbackReceiver: LoopbackRedirectReceiver, @unchecked Sendable {
    public static let callbackPath = "/oauth2callback"
    static let maxRequestBytes = 16 * 1024
    static let maxConnections = 8
    static let connectionTimeout: Duration = .seconds(10)
    static let defaultHTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenHuman Mail</title></head>"
        + "<body><p>You can close this tab.</p></body></html>"

    private let queue = DispatchQueue(label: "dev.openhuman.mail.oauth.loopback")
    private let state = Mutex(State())

    private struct State {
        var started = false
        var listener: NWListener?
        var port: UInt16?
        var stopped = false
        var delivered = false
        var expectedState: String?
        var pending: URLComponents?
        var waiter: CheckedContinuation<URLComponents, Error>?
        var waitGeneration = 0
        var abortedGeneration: Int?
        var successHTML = NWLoopbackReceiver.defaultHTML
        var openConnections = Set<ObjectIdentifier>()
    }

    public init() {}

    public func start() async throws -> URL {
        let first = state.withLock { s -> Bool in
            defer { s.started = true }
            return !s.started
        }
        guard first else { throw OAuthError.denied("loopback_receiver_reused") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let once = ResumeOnce<UInt16>()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            once.install(continuation)
            listener.stateUpdateHandler = { [weak listener] newState in
                switch newState {
                case .ready:
                    if let port = listener?.port?.rawValue, port != 0 {
                        once.resume(.success(port))
                    } else {
                        once.resume(.failure(OAuthError.denied("loopback listener has no port")))
                    }
                case .failed(let error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(OAuthError.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            state.withLock { $0.listener = listener }
            listener.start(queue: queue)
        }
        let stillWanted = state.withLock { s -> Bool in
            s.port = port
            return !s.stopped
        }
        guard stillWanted else {
            listener.cancel()
            throw OAuthError.cancelled
        }
        return URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
    }

    public func expectState(_ expected: String) async {
        state.withLock { $0.expectedState = expected }
    }

    public func waitForCallback(timeout: Duration, successHTML: String) async throws -> URLComponents {
        let generation: Int = state.withLock { s in
            s.successHTML = successHTML
            s.waitGeneration += 1
            return s.waitGeneration
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLComponents, Error>) in
                let immediate: Result<URLComponents, Error>? = state.withLock { s in
                    if let pending = s.pending {
                        s.pending = nil
                        return .success(pending)
                    }
                    if s.stopped || s.abortedGeneration == generation || s.waiter != nil {
                        return .failure(OAuthError.cancelled)
                    }
                    s.waiter = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                    return
                }
                queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in
                    guard let self else { return }
                    if self.finishWait(generation: generation, with: .failure(OAuthError.timedOut)) {
                        self.stopListening()
                    }
                }
            }
        } onCancel: {
            _ = finishWait(generation: generation, with: .failure(OAuthError.cancelled))
        }
    }

    public func stop() async {
        let waiter: CheckedContinuation<URLComponents, Error>? = state.withLock { s in
            defer { s.waiter = nil }
            return s.waiter
        }
        stopListening()
        waiter?.resume(throwing: OAuthError.cancelled)
    }

    private func stopListening() {
        let listener: NWListener? = state.withLock { s in
            s.stopped = true
            defer { s.listener = nil }
            return s.listener
        }
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admitted: Bool = state.withLock { s in
            guard !s.stopped, s.openConnections.count < Self.maxConnections,
                  Self.isLoopbackPeer(connection.endpoint) else { return false }
            s.openConnections.insert(id)
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .cancelled, .failed:
                _ = self?.state.withLock { $0.openConnections.remove(id) }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout.timeInterval) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        return address.isLoopback
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = Self.headerEnd(in: buffer) {
                self.handle(head: buffer.prefix(end), on: connection)
            } else if buffer.count >= Self.maxRequestBytes {
                Self.respond(connection, status: "431 Request Header Fields Too Large", html: "")
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    enum Verdict: Equatable {
        case reject(String)
        case callback(URLComponents)
    }

    static func classify(head: Data, port: UInt16?) -> Verdict {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let tokens = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens[2] == "HTTP/1.1" || tokens[2] == "HTTP/1.0" else {
            return .reject("400 Bad Request")
        }
        guard tokens[0] == "GET" else { return .reject("405 Method Not Allowed") }
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let port, hosts.count == 1, hosts[0] == "127.0.0.1:\(port)" else { return .reject("400 Bad Request") }
        let target = String(tokens[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: "http://127.0.0.1" + target) else {
            return .reject("400 Bad Request")
        }
        guard components.path == callbackPath else { return .reject("404 Not Found") }
        return .callback(components)
    }

    static func isValidCallback(_ components: URLComponents, expected: String?) -> Bool {
        let items = components.queryItems ?? []
        func count(_ name: String) -> Int { items.filter { $0.name == name }.count }
        guard count("code") <= 1, count("error") <= 1 else { return false }
        guard let expected else { return true }
        let states = items.filter { $0.name == "state" }.map { $0.value ?? "" }
        return states.count == 1 && constantTimeEquals(states[0], expected)
    }

    private func handle(head: Data, on connection: NWConnection) {
        let port = state.withLock { $0.port }
        let components: URLComponents
        switch Self.classify(head: head, port: port) {
        case .reject(let status):
            Self.respond(connection, status: status, html: "")
            return
        case .callback(let parsed):
            components = parsed
        }
        enum Decision { case deliver(String), invalid, gone }
        let decision: Decision = state.withLock { s in
            if s.delivered || s.stopped { return .gone }
            guard Self.isValidCallback(components, expected: s.expectedState) else { return .invalid }
            s.delivered = true
            return .deliver(s.successHTML)
        }
        switch decision {
        case .gone:
            Self.respond(connection, status: "410 Gone", html: "")
        case .invalid:
            Log(.oauth).notice("loopback receiver ignored a callback without the expected state; still waiting")
            Self.respond(connection, status: "400 Bad Request", html: "")
        case .deliver(let html):
            Self.respond(connection, status: "200 OK", html: html) { [weak self] in
                self?.deliver(components)
            }
        }
    }

    private func deliver(_ components: URLComponents) {
        let waiter: CheckedContinuation<URLComponents, Error>? = state.withLock { s in
            let waiter = s.waiter
            s.waiter = nil
            if waiter == nil { s.pending = components }
            return waiter
        }
        stopListening()
        waiter?.resume(returning: components)
    }

    private func finishWait(generation: Int, with result: Result<URLComponents, Error>) -> Bool {
        let waiter: CheckedContinuation<URLComponents, Error>? = state.withLock { s in
            guard s.waitGeneration == generation else { return nil }
            guard let waiter = s.waiter else {
                s.abortedGeneration = generation
                return nil
            }
            s.waiter = nil
            return waiter
        }
        waiter?.resume(with: result)
        return waiter != nil
    }

    private static func respond(_ connection: NWConnection, status: String, html: String,
                                then completion: (@Sendable () -> Void)? = nil) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    static func headerEnd(in buffer: Data) -> Int? {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) { return range.upperBound }
        if let range = buffer.range(of: Data("\n\n".utf8)) { return range.upperBound }
        return nil
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<T, Error>?>(nil)

    func install(_ c: CheckedContinuation<T, Error>) { continuation.withLock { $0 = c } }

    func resume(_ result: Result<T, Error>) {
        let c = continuation.withLock { value -> CheckedContinuation<T, Error>? in
            defer { value = nil }
            return value
        }
        c?.resume(with: result)
    }
}
