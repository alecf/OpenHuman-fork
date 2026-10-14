import Foundation
import MailActions
import MailModel
import OpenHumanCore

@MainActor
public final class MenuBarModel {
    public static func title(_ command: MenuBarCommand) -> String {
        switch command {
        case .openMail: "Open Mail"
        case .compose: ActionCatalog.descriptor(.compose)?.title ?? "New message"
        case .quit: "Quit Mail"
        }
    }

    public static let defaultThreadLimit = 8

    private let item: any MenuBarItemControlling
    private let counter: DockBadgeModel
    private var feed: MenuBarThreadFeed?
    private let perform: @MainActor (MenuBarCommand) -> Void
    private let openThread: @MainActor (ThreadKey) -> Void
    public private(set) var threads: [MenuBarThreadItem] = []
    public private(set) var isShown = false

    public init(data: any MailDataSource, item: any MenuBarItemControlling, preferences: SystemPreferences,
                interval: Duration = DockBadgeModel.defaultInterval,
                accountFilter: (@MainActor () -> Set<AccountID>?)? = nil,
                threadLimit: Int = MenuBarModel.defaultThreadLimit,
                openThread: @escaping @MainActor (ThreadKey) -> Void = { _ in },
                perform: @escaping @MainActor (MenuBarCommand) -> Void) {
        self.item = item
        self.perform = perform
        self.openThread = openThread
        counter = DockBadgeModel(data: data, badge: MenuBarCountSink(item: item), preferences: preferences,
                                 interval: interval, source: { preferences.menuBarCount }, accountFilter: accountFilter)
        feed = MenuBarThreadFeed(data: data, preferences: preferences, limit: threadLimit, accountFilter: accountFilter) { [weak self] items in
            guard let self else { return }
            self.threads = items
            if self.isShown { self.item.setThreads(items) { [weak self] key in self?.openThread(key) } }
        }
    }

    isolated deinit {
        feed?.stop()
        counter.stop()
        if isShown { item.hide() }
    }

    public var label: String { counter.label }
    public var total: Int { counter.total }

    public func start() {
        guard !isShown else { return }
        isShown = true
        item.show { [weak self] command in self?.perform(command) }
        counter.start()
        feed?.start()
    }

    public func refresh() {
        guard isShown else { return }
        counter.refresh()
        feed?.refresh()
    }

    public func stop() {
        guard isShown else { return }
        isShown = false
        feed?.stop()
        counter.stop()
        item.hide()
    }
}

@MainActor
private final class MenuBarCountSink: DockBadging {
    private let item: any MenuBarItemControlling

    init(item: any MenuBarItemControlling) { self.item = item }

    func setBadge(_ label: String) { item.setCount(label) }
}
