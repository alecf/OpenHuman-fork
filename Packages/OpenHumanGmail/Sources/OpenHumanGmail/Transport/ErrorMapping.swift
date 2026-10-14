import Foundation
import OpenHumanCore

struct GoogleErrorBody: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        struct Item: Decodable, Sendable { var reason: String?; var domain: String?; var message: String? }
        var code: Int?
        var message: String?
        var status: String?
        var errors: [Item]?
    }
    var error: Inner?

    var reason: String? { error?.errors?.first?.reason ?? error?.status }
    var message: String { error?.message ?? error?.errors?.first?.message ?? "" }

    static func parse(_ body: Data) -> GoogleErrorBody? {
        try? JSONDecoder().decode(GoogleErrorBody.self, from: body)
    }
}

enum GmailErrorMapping {
    static func error(status: Int, headers: [String: String], body: Data, resource: String, now: Date) -> GmailError {
        let parsed = GoogleErrorBody.parse(body)
        let reason = parsed?.reason
        let message = parsed?.message ?? ""
        let retryAfter = headers["retry-after"].flatMap { RetryAfter.parse($0, now: now) }
        switch status {
        case 400:
            return .badRequest(reason: reason, message: message)
        case 401:
            return .unauthorized
        case 403:
            switch reason {
            case "rateLimitExceeded", "userRateLimitExceeded": return .rateLimited(retryAfter: retryAfter)
            case "dailyLimitExceeded": return .dailyLimitExceeded
            default: return .forbidden(reason: reason ?? "forbidden", message: message)
            }
        case 404:
            return .notFound(resource)
        case 409:
            return .badRequest(reason: "conflict", message: message)
        case 412:
            return .preconditionFailed(message)
        case 413:
            return .payloadTooLarge
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .server(status: status, message: parsed?.error?.message)
        default:
            return .badRequest(reason: reason ?? "http \(status)", message: message)
        }
    }
}
