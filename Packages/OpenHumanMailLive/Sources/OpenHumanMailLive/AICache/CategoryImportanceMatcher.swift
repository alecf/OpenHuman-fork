import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanStore
import Synchronization

final class CategoryImportanceMatcher: ImportanceMatcher, Sendable {
    static let shared = CategoryImportanceMatcher()

    private let current = Mutex(AutoLabelIndex.off)
    private let pending = Mutex(false)

    var id: String { AutoLabelRule.matcherID }
    var readsText: Bool { false }

    func matches(_ facts: ImportanceFacts, argument: String) -> Bool {
        guard let wanted = OHGmailLabels.canonicalAutoLabelCategory(argument) else { return false }
        let index = current.withLock { $0 }
        let labelIDs = facts.messages.flatMap(\.labelIDs)
        return index.category(account: facts.accountID, thread: facts.threadID, labelIDs: labelIDs) == wanted
    }

    @discardableResult
    func update(_ index: AutoLabelIndex) -> Bool {
        current.withLock { old in
            defer { old = index }
            return old.isOn != index.isOn || old.threads != index.threads
        }
    }

    @MainActor
    static func install(on center: AutoLabelCenter?, store: any ImportanceRulesStoring) {
        ImportanceMatchers.register(shared)
        center?.onIndexChange = { index in
            guard shared.update(index) else { return }
            guard shared.pending.withLock({ busy in defer { busy = true }; return !busy }) else { return }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(2))
                shared.pending.withLock { $0 = false }
                try? store.reevaluateImportance(account: nil)
            }
        }
    }
}
