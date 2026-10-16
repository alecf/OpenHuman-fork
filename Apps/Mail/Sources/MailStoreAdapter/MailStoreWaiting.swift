import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

public protocol WaitingOverrideStoring: Sendable {
    @discardableResult
    func setWaitingOverride(_ thread: ThreadRef, _ state: WaitingOverride?) throws -> WaitingOverride?
}

extension MailStore: WaitingOverrideStoring {}

public final class MailStoreWaiting: WaitingPort, Sendable {
    private let store: any WaitingOverrideStoring

    public init(store: any WaitingOverrideStoring) {
        self.store = store
    }

    public func setChoice(_ choice: WaitingChoice?, for thread: ThreadKey) async throws -> UndoToken {
        let previous = try Self.mapping { try store.setWaitingOverride(Self.ref(thread), choice.map(Self.override)) }
        return try WaitingReceipt(thread: thread, restore: previous.map(Self.choice)).token()
    }

    public func undo(_ token: UndoToken) async throws -> UndoToken? {
        let receipt = try WaitingReceipt(token: token)
        let current = try Self.mapping { try store.setWaitingOverride(Self.ref(receipt.thread), receipt.restore.map(Self.override)) }
        return try WaitingReceipt(thread: receipt.thread, restore: current.map(Self.choice)).token()
    }

    static func override(_ choice: WaitingChoice) -> WaitingOverride {
        switch choice {
        case .notWaiting: .notWaiting
        case .waiting: .waiting
        }
    }

    static func choice(_ override: WaitingOverride) -> WaitingChoice {
        switch override {
        case .notWaiting: .notWaiting
        case .waiting: .waiting
        }
    }

    static func ref(_ key: ThreadKey) -> ThreadRef {
        ThreadRef(accountID: key.account, rowID: ThreadRowID(rawValue: key.rowID), gmailThreadID: key.gmailThreadID)
    }

    static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as StoreError {
            switch error {
            case .notFound: throw MailPortError.notFound("thread")
            default: throw MailPortError.conflict("waiting choice")
            }
        }
    }
}
