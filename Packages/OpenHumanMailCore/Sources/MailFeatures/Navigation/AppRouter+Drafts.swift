import Foundation
import MailModel

extension AppRouter {
    public static func resumesDrafts(_ location: MailLocation?) -> Bool {
        location == .system(.drafts) || location == .system(.scheduled)
    }

    public func openRow(_ key: ThreadKey) {
        guard let active, Self.resumesDrafts(active.location), let compose = environment.composeIfStarted else {
            open(key)
            return
        }
        active.list?.setCursor(key)
        let resuming = compose.resumeDraft(in: key, scheduledFirst: active.location == .system(.scheduled))
        Task { [weak self] in
            if await resuming.value == nil { self?.open(key) }
        }
        setNeedsPersist()
    }

    func opensDraftRow(_ state: AccountState) -> Bool {
        guard state === active, Self.resumesDrafts(state.location), environment.composeIfStarted != nil,
              let cursor = state.list?.cursor else { return false }
        openRow(cursor)
        return true
    }
}
