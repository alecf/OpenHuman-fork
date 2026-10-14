import Foundation
import MailModel
import OpenHumanCore

@MainActor
final class QueuedSendNotice {
    private weak var manager: ComposeManager?
    private let session: UUID
    private let account: AccountID
    private var waiting = false
    private var latest: ConnectivityState?
    private var toast: Toast.ID?
    private var watcher: Task<Void, Never>?

    static let text = String(localized: "Queued. Sends when you're back online.")

    init(manager: ComposeManager, session: UUID, account: AccountID) {
        self.manager = manager
        self.session = session
        self.account = account
    }

    func stillSending() {
        waiting = true
        update()
        guard watcher == nil, let data = manager?.environment.data else { return }
        let account = self.account
        watcher = Task { [weak self] in
            for await states in data.connectivity() {
                guard let self, !Task.isCancelled else { return }
                self.latest = states[account]
                self.update()
            }
        }
    }

    func stop() {
        waiting = false
        watcher?.cancel()
        watcher = nil
        if let toast { manager?.environment.notices.dismiss(toast) }
        toast = nil
    }

    private var isOffline: Bool {
        if case .offline? = latest ?? manager?.environment.status.connectivity[account] { return true }
        return false
    }

    private func update() {
        guard waiting, let manager else { return }
        if isOffline {
            guard toast == nil else { return }
            manager.setSending(session, .waitingForConnection)
            toast = manager.environment.notices.post(Self.text, style: .info, duration: nil,
                                                     secondary: manager.viewChoice(session))
        } else if let shown = toast {
            manager.environment.notices.dismiss(shown)
            toast = nil
            manager.setSending(session, .sending)
        }
    }
}
