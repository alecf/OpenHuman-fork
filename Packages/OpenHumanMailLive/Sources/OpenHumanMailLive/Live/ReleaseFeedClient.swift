import Foundation
import MailFeatures
import OpenHumanCore
import OpenHumanGmail

public struct ReleaseFeedClient: Sendable {
    // Why: a fixed language, or URLSession would add the person's preferred languages
    public static let headers = ["Accept": "application/vnd.github+json", "Accept-Language": "en",
                                 "X-GitHub-Api-Version": "2022-11-28"]
    public static let timeout: Duration = .seconds(15)

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    // Why: an ephemeral session with cookies off, so the request carries nothing beyond the fixed user agent
    public static func live(appVersion: String) -> ReleaseFeedClient {
        ReleaseFeedClient(transport: URLSessionTransport(userAgent: "OpenHumanMail/\(appVersion)"))
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
        } catch {
            Log(.app).notice("update check failed (\(String(describing: type(of: error))))")
            throw UpdateFeedFailure.unreachable
        }
    }
}
