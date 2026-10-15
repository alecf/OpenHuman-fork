import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension AppRouter {
    public var isAllInboxesShown: Bool { unifiedInbox != nil }

    @discardableResult
    public func goToAllInboxes() -> Bool {
        guard showsAccountSwitcher else { return false }
        if unifiedInbox != nil { return true }
        environment.calendarWindowIfStarted?.stepAside()
        let model = AllInboxesModel(accounts: accounts.map(\.account), open: { [weak self] key in
            guard let self else { return }
            self.switchAccount(to: key.account)
            self.open(key)
        }, done: { [weak self] keys in
            guard let self, let actions = self.environment.actions.threadActions else { return false }
            return actions.markDone(keys, host: self) != nil
        }, label: { [weak self] keys in
            guard let self, self.environment.overlays.canPresent(.labelPicker) else { return false }
            self.environment.overlays.present(.labelPicker(targets: keys, mode: .label))
            return true
        }, localReads: accounts.reduce(into: [:]) { $0.merge($1.localReads) { max($0, $1) } })
        unifiedInbox = model
        model.start(data: environment.data)
        return true
    }

    public func leaveAllInboxes() {
        guard let model = unifiedInbox else { return }
        model.close()
        unifiedInbox = nil
    }

    public var allInboxesUnread: Int? {
        Self.allInboxesCount(accounts.map { $0.badgeCount(accountCountMode) })
    }

    public nonisolated static func allInboxesCount(_ badges: [Int?]) -> Int? {
        let total = badges.reduce(0) { $0 + max(0, $1 ?? 0) }
        return total > 0 ? total : nil
    }

    func observeAccountCounts() {
        guard accountCountsTask == nil, let stream = environment.settings?.observe(AppSettings.accountCounts) else { return }
        accountCountsTask = Task { [weak self] in
            for await mode in stream {
                guard !Task.isCancelled else { return }
                if self?.accountCountMode != mode { self?.accountCountMode = mode }
            }
        }
    }
}
