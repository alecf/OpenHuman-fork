import Foundation
import MailModel
import OpenHumanCore

@MainActor
final class MenuBarThreadFeed {
    static let defaultLimit = MenuBarModel.defaultThreadLimit
    private static let window = 30

    private let data: any MailDataSource
    private let preferences: SystemPreferences
    private let accountFilter: (@MainActor () -> Set<AccountID>?)?
    private let limit: Int
    private let publish: @MainActor ([MenuBarThreadItem]) -> Void
    private var accountsTask: Task<Void, Never>?
    private var tasks: [AccountID: Task<Void, Never>] = [:]
    private var rows: [AccountID: [ThreadRow]] = [:]
    private var observer: UUID?
    private var last: [MenuBarThreadItem]?

    init(data: any MailDataSource, preferences: SystemPreferences, limit: Int = MenuBarThreadFeed.defaultLimit,
         accountFilter: (@MainActor () -> Set<AccountID>?)?, publish: @escaping @MainActor ([MenuBarThreadItem]) -> Void) {
        self.data = data
        self.preferences = preferences
        self.limit = limit
        self.accountFilter = accountFilter
        self.publish = publish
    }

    isolated deinit {
        accountsTask?.cancel()
        for task in tasks.values { task.cancel() }
    }

    func start() {
        guard accountsTask == nil else { return }
        observer = preferences.addObserver { [weak self] in self?.recompute() }
        let data = self.data
        accountsTask = Task { [weak self] in
            do {
                for try await accounts in data.accounts() {
                    guard let self else { return }
                    self.follow(accounts.map(\.id))
                }
            } catch {}
        }
    }

    func stop() {
        accountsTask?.cancel()
        accountsTask = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        rows = [:]
        if let observer { preferences.removeObserver(observer) }
        observer = nil
        last = nil
        publish([])
    }

    func refresh() {
        guard accountsTask != nil else { return }
        recompute()
    }

    private func follow(_ accounts: [AccountID]) {
        let wanted = Set(accounts)
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks[id] = nil
            rows[id] = nil
        }
        for id in accounts where tasks[id] == nil {
            let data = self.data
            tasks[id] = Task { [weak self] in
                do {
                    for try await window in data.threadWindow(.system(.inbox), account: id, limit: Self.window) {
                        guard let self else { return }
                        self.rows[id] = window.rows
                        self.recompute()
                    }
                } catch {}
            }
        }
        recompute()
    }

    var items: [MenuBarThreadItem] {
        let only = accountFilter?()
        let importantOnly = preferences.menuBarCount != .inbox
        let showText = !preferences.hidePreviews
        let candidates = rows.filter { only?.contains($0.key) ?? true }.values.flatMap { $0 }
            .filter { $0.isUnread && (!importantOnly || $0.isImportant) }
            .sorted { ($0.lastMessageAt, $0.id.rowID) > ($1.lastMessageAt, $1.id.rowID) }
        return candidates.prefix(limit).map { row in
            MenuBarThreadItem(key: row.id,
                              title: showText ? NotificationService.sender(of: row) : Self.hiddenTitle(important: row.isImportant),
                              detail: showText ? row.subject : "", isImportant: row.isImportant)
        }
    }

    static func hiddenTitle(important: Bool) -> String {
        important ? NotificationService.hiddenPreviewTitle : NotificationService.hiddenPreviewTitleAnyMail
    }

    private func recompute() {
        let now = items
        guard now != last else { return }
        last = now
        publish(now)
    }
}
