import Foundation
import OpenHumanCore

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let userAgent: String

    static let totalTimeoutFactor = 4

    public init(configuration: URLSessionConfiguration = .ephemeral, userAgent: String) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: configuration)
        self.userAgent = Self.userAgentWithGzip(userAgent)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if Task.isCancelled { throw TransportError.cancelled }
        let urlRequest: URLRequest = {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            urlRequest.timeoutInterval = request.timeout.timeInterval
            for (name, value) in request.headers where name.lowercased() != "user-agent" && name.lowercased() != "accept-encoding" {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            urlRequest.httpBody = request.body
            return urlRequest
        }()
        let total = request.timeout.timeInterval * Double(Self.totalTimeoutFactor)
        let session = session
        do {
            return try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask { try await Self.perform(urlRequest, session: session) }
                group.addTask {
                    try await Task.sleep(for: .seconds(total))
                    throw TransportError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw TransportError.other("no result") }
                return first
            }
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw TransportError.other(String(describing: type(of: error)))
        }
    }

    private static func perform(_ urlRequest: URLRequest, session: URLSession) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw TransportError.other("not an HTTP response") }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            throw map(error)
        }
    }

    static func userAgentWithGzip(_ userAgent: String) -> String {
        userAgent.lowercased().contains("gzip") ? userAgent : userAgent + " (gzip)"
    }

    static func map(_ error: URLError) -> TransportError {
        switch error.code {
        case .timedOut: return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .notConnected
        case .networkConnectionLost: return .connectionLost(requestMayHaveBeenSent: true)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .cannotConnect
        case .cancelled: return .cancelled
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tls("URLError \(error.code.rawValue)")
        default: return .other("URLError \(error.code.rawValue)")
        }
    }
}
