import Foundation

public enum MailPortError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported(String)
    case blockedBySafeMode
    case notFound(String)
    case conflict(String)
    case reservedLabel(String)
    case invalidQuery(String)
    case limitExceeded(String)
    case unavailable(String)

    public static let readOnlyText = "Read-only: Mail can't change your mail"

    public var description: String {
        switch self {
        case .unsupported(let what): "Not supported yet: \(what)"
        case .blockedBySafeMode: Self.readOnlyText
        case .notFound(let what): "Not found: \(what)"
        case .conflict(let why): "Changed elsewhere: \(why)"
        case .reservedLabel(let name): "\(name) is managed by Mail and can't be changed by hand"
        case .invalidQuery(let why): "Couldn't read the query: \(why)"
        case .limitExceeded(let what): "Limit reached: \(what)"
        case .unavailable(let why): "Not available right now: \(why)"
        }
    }
}
