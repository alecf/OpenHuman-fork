import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

struct OneClickUnsubscribe: Sendable {
    let store: any MailReading
    let transport: any HTTPTransport

    // Why: DenyListTransport only allows Gmail API hosts and would refuse every list host, so OneClickGuard is used here
    init(store: any MailReading, transport: any HTTPTransport) {
        self.store = store
        self.transport = OneClickGuard(wrapping: transport)
    }

    static let refusal = "an unsubscribe request other than a one-click POST over HTTPS"

    func send(_ key: MessageKey) async throws {
        guard let message = try store.message(account: key.account, gmailMessageID: key.gmailMessageID) else {
            throw MailPortError.notFound("message")
        }
        guard let url = ListUnsubscribe(header: message.listUnsubscribe, post: message.listUnsubscribePost).oneClick else {
            throw MailPortError.notFound("one-click unsubscribe")
        }
        let request = HTTPRequest(method: "POST", url: url,
                                  headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                  body: Data(ListUnsubscribe.oneClickValue.utf8), timeout: .seconds(10))
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch TransportError.refusedByGuard {
            throw MailPortError.notAllowed(Self.refusal)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log(.app).notice("account \(key.account.rawValue): one-click unsubscribe failed (\(String(describing: type(of: error))))")
            throw MailPortError.unavailable("the unsubscribe request couldn't be sent")
        }
        guard (200..<300).contains(response.status) else {
            Log(.app).notice("account \(key.account.rawValue): one-click unsubscribe answered \(response.status)")
            throw MailPortError.unavailable("the list didn't accept the unsubscribe request")
        }
        Log(.app).notice("account \(key.account.rawValue): one-click unsubscribe sent (\(response.status))")
    }
}

final class OneClickTransport: HTTPTransport {
    private let session: URLSession
    private let userAgent: String

    init(userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: OneClickRedirects(), delegateQueue: nil)
        self.userAgent = userAgent
    }

    deinit { session.finishTasksAndInvalidate() }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw TransportError.other("not https") }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout.timeInterval)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = request.body
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw TransportError.other("not an HTTP response") }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TransportError.timedOut
            case .notConnectedToInternet: throw TransportError.notConnected
            case .cancelled: throw TransportError.cancelled
            default: throw TransportError.other("URLError \(error.code.rawValue)")
            }
        }
    }
}

final class OneClickRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard response.statusCode == 307 || response.statusCode == 308, let url = request.url,
              OneClickGuard.allows(method: request.httpMethod ?? "GET", url: url,
                                   headerNames: (request.allHTTPHeaderFields ?? [:]).keys) else { return nil }
        return request
    }
}

struct OneClickGuard: HTTPTransport {
    private let wrapped: any HTTPTransport
    private static let overrideHeaders: Set<String> = ["x-http-method-override", "x-http-method", "x-method-override"]

    init(wrapping transport: any HTTPTransport) { wrapped = transport }

    private static func pathIsAllowed(_ decodedPath: String) -> Bool {
        let parts = decodedPath.split(separator: "/").map { $0.lowercased() }
        return !parts.contains(".") && !parts.contains("..") && !parts.contains("delete") && !parts.contains("batchdelete")
    }

    static func allows(method: String, url: URL, headerNames: some Sequence<String>) -> Bool {
        guard method.uppercased() == "POST", url.scheme?.lowercased() == "https",
              var host = url.host(percentEncoded: true)?.lowercased() else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        return !host.isEmpty && host != "gmail.googleapis.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && pathIsAllowed(url.path(percentEncoded: false))
            && !headerNames.contains { overrideHeaders.contains($0.lowercased()) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.allows(method: request.method, url: request.url, headerNames: request.headers.keys) else {
            throw TransportError.refusedByGuard("\(request.method) <list host>")
        }
        return try await wrapped.send(request)
    }
}
