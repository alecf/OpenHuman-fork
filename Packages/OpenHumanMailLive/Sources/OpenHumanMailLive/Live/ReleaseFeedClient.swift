import Foundation
import MailFeatures
import OpenHumanCore
import OpenHumanGmail
import Synchronization

public struct ReleaseFeedClient: Sendable {
    // Why: a fixed language, or URLSession would add the person's preferred languages
    public static let headers = ["Accept": "application/vnd.github+json", "Accept-Language": "en",
                                 "X-GitHub-Api-Version": "2022-11-28"]
    public static let timeout: Duration = .seconds(15)

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public static func live(appVersion: String) -> ReleaseFeedClient {
        ReleaseFeedClient(transport: ReleaseFeedTransport(userAgent: "OpenHumanMail/\(appVersion)"))
    }

    public var fetch: UpdateFeedFetch {
        let transport = transport
        return { url in try await Self.request(url, transport: transport) }
    }

    static func request(_ url: URL, transport: any HTTPTransport) async throws -> UpdateFeedReply {
        guard url.scheme?.lowercased() == "https" else { throw UpdateFeedFailure.unreachable }
        let query = HTTPRequest(method: "GET", url: url, headers: headers, body: nil, timeout: timeout)
        do {
            let response = try await transport.send(query)
            Log(.app).notice("update check answered \(response.status)")
            return UpdateFeedReply(status: response.status, headers: response.headers, body: response.body)
        } catch TransportError.notConnected, TransportError.cannotConnect {
            throw UpdateFeedFailure.offline
        } catch TransportError.timedOut {
            throw UpdateFeedFailure.timedOut
        } catch TransportError.refusedByGuard(ReleaseFeedTransport.redirectRefusal) {
            Log(.app).notice("update check refused a redirect")
            throw UpdateFeedFailure.redirectRefused
        } catch {
            Log(.app).notice("update check failed (\(String(describing: type(of: error))))")
            throw UpdateFeedFailure.unreachable
        }
    }
}

// Why: its own URLSession, so redirects stay on GitHub without changing the transport Gmail uses
final class ReleaseFeedTransport: HTTPTransport {
    static let redirectRefusal = "a redirect away from GitHub"

    let session: URLSession
    private let userAgent: String

    init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    deinit { session.finishTasksAndInvalidate() }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout.timeInterval)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = request.body
        let redirects = ReleaseFeedRedirects()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: redirects)
        } catch {
            throw redirects.refused ? TransportError.refusedByGuard(Self.redirectRefusal) : Self.map(error)
        }
        guard !redirects.refused else { throw TransportError.refusedByGuard(Self.redirectRefusal) }
        guard let http = response as? HTTPURLResponse else { throw TransportError.other("not an HTTP response") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    static func map(_ error: any Error) -> TransportError {
        guard let error = error as? URLError else {
            return error is CancellationError ? .cancelled : .other(String(describing: type(of: error)))
        }
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .notConnected
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .cannotConnect
        case .cancelled: return .cancelled
        default: return .other("URLError \(error.code.rawValue)")
        }
    }
}

final class ReleaseFeedRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = Mutex((hops: 0, refused: false))

    var refused: Bool { state.withLock { $0.refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let hop = state.withLock { state in
            state.hops += 1
            return state.hops
        }
        if let source = response.url, let target = request.url,
           UpdateFeed.allowsRedirect(from: source, to: target, count: hop) {
            return request
        }
        state.withLock { $0.refused = true }
        task.cancel()
        return nil
    }
}
