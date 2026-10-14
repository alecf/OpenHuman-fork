import Foundation

public enum WaitingChoice: String, Codable, Sendable, Hashable {
    case notWaiting
    case waiting
}

public struct WaitingReceipt: Codable, Sendable, Hashable {
    public let thread: ThreadKey
    public let restore: WaitingChoice?

    public init(thread: ThreadKey, restore: WaitingChoice?) {
        self.thread = thread
        self.restore = restore
    }

    public func token() throws -> UndoToken { UndoToken(payload: try JSONEncoder().encode(self)) }

    public init(token: UndoToken) throws {
        do { self = try JSONDecoder().decode(WaitingReceipt.self, from: token.payload) } catch {
            throw MailPortError.conflict("not a waiting receipt")
        }
    }
}

public protocol WaitingPort: MailUndoing {
    func setChoice(_ choice: WaitingChoice?, for thread: ThreadKey) async throws -> UndoToken
}
