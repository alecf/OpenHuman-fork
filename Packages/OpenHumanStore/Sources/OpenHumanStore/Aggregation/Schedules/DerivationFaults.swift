import Foundation
#if DEBUG
import Synchronization
#endif

enum DerivationFaults {
    enum Kind: String, Sendable { case snooze, sendLater }

    struct Injected: Error, Equatable { var kind: Kind }

    #if DEBUG
    private static let poisoned = Mutex<Set<String>>([])

    static func inject(_ kind: Kind, thread gmailThreadID: String) {
        _ = poisoned.withLock { $0.insert(kind.rawValue + ":" + gmailThreadID) }
    }

    static func clear(_ kind: Kind, thread gmailThreadID: String) {
        _ = poisoned.withLock { $0.remove(kind.rawValue + ":" + gmailThreadID) }
    }
    #endif

    static func check(_ kind: Kind, thread gmailThreadID: String) throws {
        #if DEBUG
        if poisoned.withLock({ $0.contains(kind.rawValue + ":" + gmailThreadID) }) { throw Injected(kind: kind) }
        #endif
    }
}
