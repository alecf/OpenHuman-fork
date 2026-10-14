import Foundation
import MailModel
import OpenHumanCore

@MainActor
public final class DockBadgeModel {
    public static let defaultInterval: Duration = .seconds(1)

    private let data: any MailDataSource
    private let badge: any DockBadging
    private let preferences: SystemPreferences
    private let source: (@MainActor () -> DockBadgeSource)?
    private let accountFilter: (@MainActor () -> Set<AccountID>?)?
    private let interval: Duration
    private var accountsTask: Task<Void, Never>?
    private var countTasks: [AccountID: Task<Void, Never>] = [:]
    private var counts: [AccountID: MailboxCountsInfo] = [:]
    private var observer: UUID?
    private var timer: Task<Void, Never>?
    private var dirty = false
    public private(set) var label = ""

    public init(data: any MailDataSource, badge: any DockBadging, preferences: SystemPreferences,
                interval: Duration = DockBadgeModel.defaultInterval, source: (@MainActor () -> DockBadgeSource)? = nil,
                accountFilter: (@MainActor () -> Set<AccountID>?)? = nil) {
        self.data = data
        self.badge = badge
        self.preferences = preferences
        self.source = source
        self.accountFilter = accountFilter
        self.interval = interval
    }

    isolated deinit {
        accountsTask?.cancel()
        timer?.cancel()
        for task in countTasks.values { task.cancel() }
    }

    public func start() {
        guard accountsTask == nil else { return }
        observer = preferences.addObserver { [weak self] in self?.changed() }
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

    public func stop() {
        accountsTask?.cancel()
        accountsTask = nil
        for task in countTasks.values { task.cancel() }
        countTasks = [:]
        timer?.cancel()
        timer = nil
        if let observer { preferences.removeObserver(observer) }
        observer = nil
        counts = [:]
        apply("")
    }

    private func follow(_ accounts: [AccountID]) {
        let wanted = Set(accounts)
        for (id, task) in countTasks where !wanted.contains(id) {
            task.cancel()
            countTasks[id] = nil
            counts[id] = nil
        }
        for id in accounts where countTasks[id] == nil {
            let data = self.data
            countTasks[id] = Task { [weak self] in
                do {
                    for try await value in data.counts(id) {
                        guard let self else { return }
                        self.counts[id] = value
                        self.changed()
                    }
                } catch {}
            }
        }
        changed()
    }

    public var total: Int {
        let only = accountFilter?()
        let counted = counts.filter { only?.contains($0.key) ?? true }.values
        switch source?() ?? preferences.dockBadge {
        case .important: return counted.reduce(0) { $0 + ($1.importantUnread ?? 0) }
        case .inbox: return counted.reduce(0) { $0 + $1.inboxUnread }
        case .off: return 0
        }
    }

    public func refresh() {
        guard accountsTask != nil else { return }
        changed()
    }

    public static func text(for total: Int) -> String {
        total <= 0 ? "" : (total > 999 ? "999+" : String(total))
    }

    private func changed() {
        if timer != nil {
            dirty = true
            return
        }
        apply(Self.text(for: total))
        let interval = self.interval
        timer = Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if self.dirty {
                    self.dirty = false
                    self.apply(Self.text(for: self.total))
                } else {
                    self.timer = nil
                    return
                }
            }
        }
    }

    private func apply(_ text: String) {
        guard text != label else { return }
        label = text
        badge.setBadge(text)
    }
}
