import Foundation
import OpenHumanGmail
import Synchronization

public final class FixtureTransport: HTTPTransport {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noFixture(method: String, path: String, query: [String: String])
        case unreadable(name: String)
        public var description: String {
            switch self {
            case let .noFixture(m, p, q): return "no fixture for \(m) \(p) \(q)"
            case let .unreadable(name): return "unreadable fixture \(name)"
            }
        }
    }

    public struct Fixture: Sendable {
        public var name: String
        public var method: String
        public var path: String
        public var query: [String: String]
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        public init(name: String = "inline", method: String = "GET", path: String, query: [String: String] = [:],
                    status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.name = name; self.method = method; self.path = path; self.query = query
            self.status = status; self.headers = headers; self.body = body
        }
    }

    private struct State { var requests: [HTTPRequest] = [] }
    private let state = Mutex(State())
    public let fixtures: [Fixture]

    public init(fixtures: [Fixture]) { self.fixtures = fixtures }

    public convenience init(directory: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        self.init(fixtures: try names.map { try Self.load(directory.appendingPathComponent($0), name: $0) })
    }

    public var requests: [HTTPRequest] { state.withLock { $0.requests } }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        state.withLock { $0.requests.append(request) }
        let path = request.url.path(percentEncoded: false)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value ?? "" }
        let best = fixtures.filter { $0.method == request.method && $0.path == path
            && $0.query.allSatisfy { query[$0.key] == $0.value } }.max { $0.query.count < $1.query.count }
        guard let best else { throw Failure.noFixture(method: request.method, path: path, query: query) }
        return HTTPResponse(status: best.status, headers: best.headers, body: best.body)
    }

    static func load(_ url: URL, name: String) throws -> Fixture {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = root["request"] as? [String: Any], let response = root["response"] as? [String: Any],
              let path = request["path"] as? String, let status = response["status"] as? Int else {
            throw Failure.unreadable(name: name)
        }
        var body = Data()
        if let text = response["body"] as? String { body = Data(text.utf8) }
        else if let object = response["body"], !(object is NSNull) {
            guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else {
                throw Failure.unreadable(name: name)
            }
            body = d
        } else if let b64 = response["bodyBase64"] as? String, let d = Data(base64Encoded: b64) { body = d }
        let query = (request["query"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        return Fixture(name: name, method: (request["method"] as? String ?? "GET").uppercased(), path: path,
                       query: query, status: status, headers: response["headers"] as? [String: String] ?? [:], body: body)
    }
}
