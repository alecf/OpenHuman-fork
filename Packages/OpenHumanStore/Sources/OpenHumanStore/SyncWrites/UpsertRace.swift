import Foundation
#if DEBUG
import Synchronization
#endif

enum UpsertRace {
    #if DEBUG
    private static let hooks = Mutex<[String: @Sendable () -> Void]>([:])

    static func before(_ gmailMessageID: String, run: @escaping @Sendable () -> Void) {
        hooks.withLock { $0[gmailMessageID] = run }
    }

    static func clear(_ gmailMessageID: String) {
        _ = hooks.withLock { $0.removeValue(forKey: gmailMessageID) }
    }
    #endif

    static func willUpsert(_ messages: [MessageUpsert]) {
        #if DEBUG
        let due = hooks.withLock { h in messages.compactMap { h.removeValue(forKey: $0.gmailMessageID.rawValue) } }
        for run in due { run() }
        #endif
    }
}
