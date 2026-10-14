import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

extension OperationDrainer {
    enum Disposition: Sendable {
        case complete(OperationOutcome)
        case retry(code: String, message: String, at: Date?, limit: Int)
        case release(at: Date)
        case fail(code: String, message: String)
        case cancel(code: String, message: String)
    }

    struct Decision: Sendable {
        var disposition: Disposition
        var stopPass = false
        var pauseForReauth = false
        var event: EngineEvent? = nil

        init(_ disposition: Disposition, stopPass: Bool = false, pauseForReauth: Bool = false, event: EngineEvent? = nil) {
            self.disposition = disposition
            self.stopPass = stopPass
            self.pauseForReauth = pauseForReauth
            self.event = event
        }
    }

    static func classify(_ error: Error, now: Date, limit: Int = maxAttempts) -> Decision {
        switch error {
        case let gmail as GmailError:
            return classify(gmail, now: now, limit: limit)
        case is LabelBook.Unresolved:
            return Decision(.retry(code: "label_conflict", message: "the label name is taken but not listed",
                                   at: nil, limit: limit))
        case DraftMessage.Failure.attachmentMissing(let which):
            return Decision(.fail(code: "attachment_missing", message: which))
        case let mime as MIMEError:
            switch mime {
            case .tooLarge: return Decision(.fail(code: "payload_too_large", message: "message larger than 35 MB"))
            case .invalidHeader(let what): return Decision(.fail(code: "mime_invalid", message: "invalid \(what)"))
            case .missingBody: return Decision(.fail(code: "mime_invalid", message: "no body"))
            case .malformed(let what): return Decision(.fail(code: "mime_invalid", message: what))
            }
        case let fetch as AttachmentFetcher.Failure:
            switch fetch {
            case .tooLarge(let bytes): return Decision(.fail(code: "payload_too_large", message: "attachment of \(bytes) bytes"))
            case .notFound, .noContent: return Decision(.fail(code: "attachment_missing", message: "forwarded attachment"))
            }
        case is CancellationError:
            return Decision(.release(at: now), stopPass: true)
        default:
            return Decision(.retry(code: "error", message: String(describing: type(of: error)), at: nil, limit: limit))
        }
    }

    static func classify(_ gmail: GmailError, now: Date, limit: Int) -> Decision {
        switch gmail {
        case .transport(.notConnected), .transport(.cannotConnect):
            return Decision(.release(at: now.addingTimeInterval(offlineRetry.timeInterval)), stopPass: true)
        case .rateLimited(let after):
            return Decision(.release(at: now.addingTimeInterval((after ?? defaultRateLimitRetry).timeInterval)), stopPass: true)
        case .dailyLimitExceeded:
            return Decision(.release(at: nextUTCMidnight(after: now).addingTimeInterval(300)), stopPass: true)
        case .quotaBudgetExhausted:
            return Decision(.release(at: now.addingTimeInterval(60)), stopPass: true)
        case .cancelled, .transport(.cancelled):
            return Decision(.release(at: now), stopPass: true)
        case .unauthorized, .reauthRequired:
            return Decision(.release(at: now), stopPass: true, pauseForReauth: true)
        case .transport(.blockedBySafeMode(let what)):
            return Decision(.fail(code: "safe_mode_blocked", message: what))
        case .badRequest(_, let message):
            return Decision(.fail(code: "bad_request", message: message))
        case .forbidden(let reason, let message):
            return Decision(.fail(code: "forbidden", message: "\(reason): \(message)"))
        case .payloadTooLarge:
            return Decision(.fail(code: "payload_too_large", message: "413"))
        case .preconditionFailed(let message):
            return Decision(.fail(code: "precondition_failed", message: message))
        case .notFound, .server, .transport, .decoding, .historyExpired:
            return Decision(.retry(code: code(gmail), message: String(describing: gmail), at: nil, limit: limit))
        }
    }

    static func neverReachedGmail(_ error: Error) -> Bool {
        guard let gmail = error as? GmailError else { return false }
        switch gmail {
        case .transport(.notConnected), .transport(.cannotConnect), .rateLimited, .dailyLimitExceeded,
             .quotaBudgetExhausted, .unauthorized, .reauthRequired, .transport(.blockedBySafeMode):
            return true
        default:
            return false
        }
    }

    static func code(_ error: Error) -> String {
        guard let gmail = error as? GmailError else { return error is CancellationError ? "cancelled" : "error" }
        switch gmail {
        case .server: return "server"
        case .transport(.blockedBySafeMode): return "safe_mode_blocked"
        case .transport: return "transport"
        case .notFound: return "not_found"
        case .decoding: return "decoding"
        case .badRequest: return "bad_request"
        case .rateLimited: return "rate_limited"
        case .cancelled: return "cancelled"
        case .unauthorized, .reauthRequired: return "reauth"
        default: return "error"
        }
    }
}
