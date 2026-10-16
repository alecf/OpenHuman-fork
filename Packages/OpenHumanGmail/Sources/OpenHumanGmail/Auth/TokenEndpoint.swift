import Foundation
import OpenHumanCore

struct TokenEndpointResponse: Decodable, Sendable {
    var accessToken: String?
    var expiresIn: Int?
    var refreshToken: String?
    var scope: String?
    var tokenType: String?
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token"
        case scope, tokenType = "token_type", error, errorDescription = "error_description"
    }

    var grantedScopes: [String] { OAuthScopes.parse(scope) }
}

enum TokenEndpoint {
    struct Reply: Sendable {
        var status: Int
        var body: TokenEndpointResponse?
    }

    static let refreshRetryWaits: [Duration] = [.seconds(1), .seconds(2)]

    static func post(form: [(String, String)], to url: URL, transport: any HTTPTransport, clock: any OHClock,
                     retryWaits: [Duration]) async throws -> Reply {
        let request = HTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(formEncode(form).utf8))
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let canRetry = attempt < retryWaits.count
            do {
                let response = try await transport.send(request)
                if (500...599).contains(response.status), canRetry {
                    Log(.oauth).notice("token endpoint returned \(response.status); retrying")
                } else {
                    let body = try? JSONDecoder().decode(TokenEndpointResponse.self, from: response.body)
                    return Reply(status: response.status, body: body)
                }
            } catch let error as TransportError {
                switch error {
                case .cancelled, .refusedByGuard: throw error
                default:
                    guard canRetry else { throw error }
                    Log(.oauth).notice("token endpoint transport error; retrying")
                }
            }
            try await clock.sleep(for: retryWaits[attempt])
            attempt += 1
        }
    }

    static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func failure(_ reply: Reply) -> OAuthError {
        .tokenEndpoint(status: reply.status, error: reply.body?.error, description: reply.body?.errorDescription)
    }
}
