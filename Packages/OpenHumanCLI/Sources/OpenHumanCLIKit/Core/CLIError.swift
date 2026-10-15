import ArgumentParser
import Foundation
import OpenHumanStore
import OpenHumanSync
import OpenHumanCore

public enum CLIStatus: Int32, Sendable, CaseIterable {
    case ok = 0, failure, usage, notFound, authRequired, policyBlocked, queued, busy, rateLimited
    case incompatible, partial, offline, appRequired, notImplemented

    public var label: String {
        switch self {
        case .ok: return "ok"
        case .failure: return "failure"
        case .usage: return "usage"
        case .notFound: return "not_found"
        case .authRequired: return "auth_required"
        case .policyBlocked: return "policy_blocked"
        case .queued: return "queued"
        case .busy: return "busy"
        case .rateLimited: return "rate_limited"
        case .incompatible: return "incompatible"
        case .partial: return "partial"
        case .offline: return "offline"
        case .appRequired: return "app_required"
        case .notImplemented: return "not_implemented"
        }
    }

    public var meaning: String {
        switch self {
        case .ok: return "success"
        case .failure: return "unexpected runtime error"
        case .usage: return "bad arguments, ambiguous label or account, confirmation required under --no-input"
        case .notFound: return "thread, message, draft or account not in the cache"
        case .authRequired: return "no account, or the account needs reauthorization in the app"
        case .policyBlocked: return "read-only run (--readonly), mail_changes_in_app, send_not_supported, not_supported, reserved_label or command not allowed"
        case .queued: return "write accepted and queued; the app has not confirmed it yet"
        case .busy: return "the store stayed busy beyond retries"
        case .rateLimited: return "Gmail rate limit and the command needed the network"
        case .incompatible: return "database schema newer than this CLI, or SQLite without FTS5"
        case .partial: return "a batch succeeded for some items and failed for others"
        case .offline: return "the command needed the network and it is unreachable"
        case .appRequired: return "the command needs Gmail access, which only the app has in Phase 1"
        case .notImplemented: return "listed in schema.json but not built in this release"
        }
    }
}

public struct CLIExit: Error, Equatable, Sendable {
    public var code: Int32
    public init(_ code: Int32) { self.code = code }
}

public struct CLIError: Error, Sendable {
    public var code: String
    public var message: String
    public var status: CLIStatus
    public var details: [String: OutValue]

    public init(_ code: String, _ message: String, _ status: CLIStatus, details: [String: OutValue] = [:]) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }

    static func usage(_ message: String, code: String = "usage", details: [String: OutValue] = [:]) -> CLIError {
        CLIError(code, message, .usage, details: details)
    }
    static func notFound(_ what: String, id: String? = nil) -> CLIError {
        CLIError("not_found", "\(what) not found in the local cache.", .notFound,
                 details: id.map { ["id": .string($0)] } ?? [:])
    }
    static func policy(_ code: String, _ message: String, details: [String: OutValue] = [:]) -> CLIError {
        CLIError(code, message, .policyBlocked, details: details)
    }
    static func appRequired(_ message: String) -> CLIError { CLIError("app_required", message, .appRequired) }
    static let noAccount = CLIError("no_account", "No account in the local store. Add one in OpenHuman Mail.", .authRequired)

    public static func map(_ error: Error) -> CLIError {
        switch error {
        case let e as CLIError:
            return e
        case let e as StoreError:
            return map(e)
        case let e as EngineError:
            return map(e)
        case let e as WhenParserError:
            switch e {
            case .empty: return .usage("A date or time is required.", code: "bad_date")
            case .unrecognized: return .usage("Could not read that date or time. Try ISO 8601, \"tomorrow 8am\" or \"+2h\".", code: "bad_date")
            }
        case is ValidationError:
            return .usage("Invalid arguments.")
        default:
            return CLIError("failure", "Unexpected error (\(type(of: error))).", .failure)
        }
    }

    static func map(_ error: StoreError) -> CLIError {
        switch error {
        case .notFound: return .notFound("The requested item")
        case .readOnly: return .policy("readonly", "The store is open read-only.")
        case .busy: return CLIError("busy", "The store is busy. Try again.", .busy)
        case .schemaTooNew:
            return CLIError("schema_too_new", "The database was written by a newer OpenHuman Mail. Update this CLI.", .incompatible)
        case .sqliteMissingFeature:
            return CLIError("sqlite_feature_missing", "This SQLite build lacks a required feature (FTS5).", .incompatible)
        case .invalidQuery(_, let position):
            return .usage("The search query could not be parsed.", code: "invalid_query",
                          details: position.map { ["position": .int($0)] } ?? [:])
        case .unsupportedView: return .usage("That view is not supported here.", code: "unsupported_view")
        case .conflict: return CLIError("conflict", "The item changed or is in a state that does not allow this.", .failure)
        case .accountNotActive:
            return CLIError("account_not_active", "The account is not active. Open OpenHuman Mail.", .authRequired)
        case .integrity: return CLIError("integrity", "The store reported an integrity problem. Run `openhuman doctor`.", .failure)
        case .reservedLabel:
            return .policy("reserved_label", "OpenHuman schedule labels are reserved. Use snooze, unsnooze or remind.")
        case .limitExceeded: return CLIError("limit_exceeded", "A store limit was reached.", .failure)
        }
    }

    static func map(_ error: EngineError) -> CLIError {
        switch error {
        case .requiresApp:
            return .appRequired("This needs Gmail access, which only OpenHuman Mail has. Open the app.")
        case .sendNotAllowed:
            return .policy("send_not_supported", "The CLI does not send mail. Create a draft and send it from OpenHuman Mail.")
        case .oauthClientMissing:
            return .appRequired("No OAuth client is configured. Open OpenHuman Mail.")
        case .writeAccessMissing:
            return CLIError("auth_required", "The account needs to be reauthorized in OpenHuman Mail to allow changes.", .authRequired)
        }
    }
}
