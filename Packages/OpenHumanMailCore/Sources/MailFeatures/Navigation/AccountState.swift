import Foundation
import MailModel
import Observation
import OpenHumanCore

public struct MailTab: Identifiable, Hashable, Sendable {
    public var id: MailLocation { location }
    public let location: MailLocation
    public let title: String
    public let unread: Int
    public let total: Int?

    public init(location: MailLocation, title: String, unread: Int, total: Int? = nil) {
        self.location = location
        self.title = title
        self.unread = unread
        self.total = total
    }

    public func withHiddenRows(_ hidden: Int) -> MailTab {
        guard hidden > 0, let total else { return self }
        return MailTab(location: location, title: title, unread: unread, total: max(0, total - hidden))
    }

    public func count(_ mode: TabCountMode) -> Int {
        switch mode {
        case .all: total ?? 0
        case .unread: unread
        }
    }
}

public struct SidebarItem: Identifiable, Hashable, Sendable {
    public var id: MailLocation { location }
    public let location: MailLocation
    public let title: String
    public let count: Int?
    public let symbol: String
    public let depth: Int

    public init(location: MailLocation, title: String, count: Int?, symbol: String, depth: Int = 0) {
        self.location = location
        self.title = title
        self.count = count
        self.symbol = symbol
        self.depth = depth
    }
}

@MainActor
@Observable
public final class AccountState: Identifiable {
    public enum Mode: Equatable, Sendable { case list, reader }

    public let id: AccountID
    public private(set) var account: Account
    public private(set) var location: MailLocation?
    public private(set) var mode: Mode = .list
    public private(set) var list: ThreadListModel?
    public private(set) var reader: ReaderModel?
    public let selection = SelectionModel()
    public private(set) var splits: [SplitInfo] = []
    public private(set) var labels: [LabelInfo] = []
    public private(set) var counts: MailboxCountsInfo?
    public private(set) var hiddenWhenEmpty: Set<String> = []
    public private(set) var tabCountMode: TabCountMode = AppSettings.tabCounts.defaultValue
    public private(set) var splitsLoaded = false
    public private(set) var lastTab: MailLocation?
    @ObservationIgnored private var lastRestorable: MailLocation?

    @ObservationIgnored let environment: AppEnvironment
    public var searchText = ""
    public var searchOpen = false

    @ObservationIgnored private var restoredPlace: AccountPlace?
    @ObservationIgnored private var locationWasRestored = false
    @ObservationIgnored private var cursorFallback: ThreadKey?
    @ObservationIgnored private weak var readerSource: (any ReaderStateRestorable)?
    @ObservationIgnored private var pendingReaderPlace: (thread: ThreadKey, place: ReaderPlace)?
    @ObservationIgnored private let startLocation: MailLocation?
    @ObservationIgnored private var chromeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var readerRestore: Task<Void, Never>?
    @ObservationIgnored private var readMark: Task<Void, Never>?
    @ObservationIgnored private(set) var localReads: [ThreadKey: Date] = [:]
    @ObservationIgnored private var detour: (thread: ThreadKey, anchor: ThreadKey, afterAnchor: Bool)?
    @ObservationIgnored private(set) var started = false

    init(account: Account, environment: AppEnvironment, start: MailLocation?, place: AccountPlace?) {
        self.id = account.id
        self.account = account
        self.environment = environment
        self.startLocation = start
        self.restoredPlace = place.flatMap { AccountPlace.isRestorable($0.location) ? $0 : nil }
    }

    isolated deinit {
        for task in chromeTasks { task.cancel() }
        countsTask?.cancel()
        readerRestore?.cancel()
        readMark?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        observeChrome()
        if let place = restoredPlace {
            restoredPlace = nil
            selection.pendingCursor = place.cursor
            cursorFallback = place.cursorFallback
            selection.scrollTop = place.scrollTop
            selection.scrollOffset = place.scrollOffset
            selection.restoreChecked(place.checked)
            searchText = place.searchText
            searchOpen = place.searchOpen
            if let open = place.openThread, let reader = place.reader { pendingReaderPlace = (open, reader) }
            locationWasRestored = true
            show(place.location)
            if let open = place.openThread { restoreReader(open) }
        } else if let startLocation {
            show(startLocation)
        }
    }

    func stop() {
        for task in chromeTasks { task.cancel() }
        chromeTasks = []
        countsTask?.cancel()
        countsTask = nil
        readerRestore?.cancel()
        readMark?.cancel()
        list?.stop()
        reader?.stop()
    }

    func update(_ account: Account) {
        if account != self.account { self.account = account }
    }

    func followCounts() {
        guard countsTask == nil else { return }
        let stream = environment.data.counts(id)
        countsTask = Task { [weak self] in
            do {
                for try await counts in stream {
                    guard !Task.isCancelled else { return }
                    self?.counts = counts
                }
            } catch {}
        }
    }

    private func observeChrome() {
        let data = environment.data
        let account = id
        let splitsStream = data.splits(account)
        let labelsStream = data.labels(account)
        followCounts()
        let hiddenStream = environment.settings?.observe(AppSettings.hideSplitWhenEmpty(account))
        let tabCountStream = environment.settings?.observe(AppSettings.tabCounts)
        chromeTasks = [
            Task { [weak self] in
                do {
                    for try await splits in splitsStream {
                        guard !Task.isCancelled else { return }
                        self?.applySplits(splits)
                    }
                } catch {}
                guard !Task.isCancelled else { return }
                self?.applySplitsFinished()
            },
            Task { [weak self] in
                do {
                    for try await labels in labelsStream {
                        guard !Task.isCancelled else { return }
                        self?.labels = labels
                    }
                } catch {}
            },
            Task { [weak self] in
                guard let hiddenStream else { return }
                for await list in hiddenStream {
                    guard !Task.isCancelled else { return }
                    self?.hiddenWhenEmpty = Set(list)
                }
            },
            Task { [weak self] in
                guard let tabCountStream else { return }
                for await mode in tabCountStream {
                    guard !Task.isCancelled else { return }
                    if self?.tabCountMode != mode { self?.tabCountMode = mode }
                }
            },
        ]
    }

    private func applySplits(_ value: [SplitInfo]) {
        let first = !splitsLoaded
        splits = value.filter(\.enabled).sorted { ($0.position, $0.name) < ($1.position, $1.name) }
        splitsLoaded = true
        resolveLocationAfterSplits(firstAnswer: first)
    }

    private func applySplitsFinished() {
        guard !splitsLoaded else { return }
        splitsLoaded = true
        resolveLocationAfterSplits()
    }

    private func resolveLocationAfterSplits(firstAnswer: Bool = false) {
        guard let location else {
            show(firstTab)
            return
        }
        if firstAnswer, locationWasRestored, location == .system(.inbox), !splits.isEmpty {
            lastTab = nil
            go(to: firstTab)
            return
        }
        if tabs.contains(where: { $0.location == location }) { lastTab = location }
        if case .split(let key) = location, !splits.contains(where: { $0.id == key }) { go(to: firstTab) }
    }

    var allTabs: [MailTab] {
        guard !splits.isEmpty else {
            let unread = counts?.inboxUnread ?? (location == .system(.inbox) ? list?.rows.filter(\.isUnread).count : nil) ?? 0
            let inbox = labels.first { $0.labelID == GmailLabelID("INBOX") }
            let total = inbox.map { counts?.byLabel[$0.id]?.total ?? $0.totalThreads }
            return [MailTab(location: .system(.inbox), title: "Inbox", unread: unread, total: total)]
        }
        let all = splits.map { split in
            MailTab(location: .split(split.id), title: split.name, unread: counts?.splitUnread[split.id] ?? split.unreadThreads,
                    total: split.totalThreads)
        } + [MailTab(location: .splitOther, title: "Other", unread: counts?.otherUnread ?? 0,
                     total: counts?.otherTotal(labels: labels, splits: splits))]
        guard let list, list.optimisticHiddenCount > 0 else { return all }
        return all.map { $0.location == list.location ? $0.withHiddenRows(list.optimisticHiddenCount) : $0 }
    }

    public var tabs: [MailTab] {
        guard !hiddenWhenEmpty.isEmpty else { return allTabs }
        return allTabs.filter { tab in
            guard tab.total == 0, tab.unread == 0, tab.location != location, let token = Self.hideToken(tab.location) else { return true }
            return !hiddenWhenEmpty.contains(token)
        }
    }

    public func hidesWhenEmpty(_ location: MailLocation) -> Bool? {
        guard environment.settings != nil, let token = Self.hideToken(location) else { return nil }
        return hiddenWhenEmpty.contains(token)
    }

    public func setHidesWhenEmpty(_ location: MailLocation, _ hidden: Bool) async {
        guard let settings = environment.settings, let token = Self.hideToken(location) else { return }
        var next = hiddenWhenEmpty
        if hidden { next.insert(token) } else { next.remove(token) }
        do { try await settings.set(AppSettings.hideSplitWhenEmpty(id), next.sorted()) } catch {
            environment.notices.post("Couldn't change Hide when empty", style: .error)
        }
    }

    private static func hideToken(_ location: MailLocation) -> String? {
        switch location {
        case .split(let key): key.rawValue
        case .splitOther: AppSettings.otherSplitToken
        default: nil
        }
    }

    public var firstTab: MailLocation { tabs.first?.location ?? .system(.inbox) }

    public func tabCount(_ tab: MailTab) -> Int { tab.count(tabCountMode) }

    public var mutedLabel: LabelInfo? { labels.first { $0.name == OHGmailLabels.muted } }

    public var isOnTab: Bool { location.map { loc in tabs.contains { $0.location == loc } } ?? true }

    public var firstTabUnread: Int { tabs.first?.unread ?? 0 }

    public var switcherCount: Int { counts?.importantUnread ?? firstTabUnread }

    public nonisolated static func switcherBadge(_ count: Int) -> String? {
        count <= 0 ? nil : (count > 99 ? "99+" : String(count))
    }

    public func title(for location: MailLocation) -> String {
        if let tab = tabs.first(where: { $0.location == location }) { return tab.title }
        switch location {
        case .system(let folder): return Self.title(of: folder)
        case .split: return "Split"
        case .splitOther: return "Other"
        case .label(let id) where id == mutedLabel?.labelID: return "Muted"
        case .label(let id): return labels.first { $0.labelID == id }?.name ?? "Label"
        case .reviewQueue: return "Review queue"
        case .search(let query): return "Results for “\(query)”"
        }
    }

    public nonisolated static func title(of folder: SystemFolder) -> String {
        switch folder {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .important: "Important"
        case .unread: "Unread"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .allMail: "All mail"
        case .trash: "Trash"
        case .spam: "Spam"
        case .snoozed: "Snoozed"
        case .scheduled: "Scheduled"
        case .reminders: "Reminders"
        case .done: "Done"
        case .waiting: "Waiting"
        }
    }

    public var sidebarItems: [SidebarItem] {
        var items = tabs.map { SidebarItem(location: $0.location, title: $0.title, count: $0.unread == 0 ? nil : $0.unread,
                                           symbol: $0.location == .system(.inbox) ? "tray" : "line.3.horizontal") }
        func label(_ key: String) -> LabelInfo? { labels.first { $0.labelID.rawValue == key } }
        func nonZero(_ value: Int?) -> Int? { value.flatMap { $0 == 0 ? nil : $0 } }
        let system: [(SystemFolder, String, Int?)] = [
            (.starred, "star", nil),
            (.snoozed, "clock", nonZero(label("oh:snoozed")?.totalThreads)),
            (.reminders, "bell", nonZero(label("oh:reminders")?.totalThreads)),
            (.waiting, "hourglass", nonZero(label("oh:waiting")?.totalThreads)),
            (.scheduled, "calendar.badge.clock", nonZero(label("oh:scheduled")?.totalThreads)),
            (.drafts, "doc", nonZero(counts?.draftsCount ?? label("DRAFT")?.totalThreads)),
            (.sent, "paperplane", nil),
            (.done, "checkmark.circle", nil),
            (.allMail, "archivebox", nil),
            (.spam, "xmark.octagon", nonZero(label("SPAM")?.unreadThreads)),
            (.trash, "trash", nil),
        ]
        items += system.map { SidebarItem(location: .system($0.0), title: Self.title(of: $0.0), count: $0.2, symbol: $0.1) }
        if let muted = mutedLabel, let after = items.firstIndex(where: { $0.location == .system(.scheduled) }) {
            items.insert(SidebarItem(location: .label(muted.labelID), title: "Muted", count: nil, symbol: "speaker.slash"),
                         at: after + 1)
        }
        if let pending = counts?.pendingReviewCount, pending > 0 {
            items.append(SidebarItem(location: .reviewQueue(nil), title: "Review queue", count: pending, symbol: "doc.badge.ellipsis"))
        }
        let superhuman = environment.superhumanLabels
        let userLabels = labels
            .filter { $0.kind == .user && !$0.isHidden && !$0.name.hasPrefix(OHGmailLabels.root + "/") }
            .filter { !superhuman.hides($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items += userLabels.map { label in
            SidebarItem(location: .label(label.labelID), title: label.displayName, count: nonZero(label.unreadThreads),
                        symbol: "tag", depth: label.name.split(separator: "/").count - 1)
        }
        return items
    }

    public func go(to location: MailLocation) {
        closeReader()
        guard location != self.location || list == nil else { return }
        selection.clearChecked()
        selection.pendingCursor = nil
        cursorFallback = nil
        selection.scrollTop = nil
        selection.scrollOffset = 0
        show(location)
    }

    @discardableResult
    public func cycleTab(by delta: Int) -> Bool {
        guard splitsLoaded else { return true }
        let tabs = self.tabs
        guard !tabs.isEmpty else { return false }
        guard let location, let index = tabs.firstIndex(where: { $0.location == location }) else {
            go(to: tabs[0].location)
            return true
        }
        guard tabs.count > 1 else { return true }
        let next = ((index + delta) % tabs.count + tabs.count) % tabs.count
        go(to: tabs[next].location)
        return true
    }

    private func show(_ location: MailLocation) {
        self.location = location
        if AccountPlace.isRestorable(location) { lastRestorable = location }
        if tabs.contains(where: { $0.location == location }) { lastTab = location }
        list?.stop()
        let model = ThreadListModel(data: environment.data, location: location, account: id)
        model.attachAutoLabels(environment.autoLabels)
        model.attachSuperhumanLabels(environment.superhumanLabels)
        model.attachVIPs(environment.vips)
        if !localReads.isEmpty { model.seedLocalReads(localReads) }
        list = model
        model.start()
        if let pending = selection.pendingCursor { restoreCursor(pending, in: model) }
    }

    func restoreCursor(_ key: ThreadKey, in model: ThreadListModel, updates: Int = 0) {
        selection.pendingCursor = key
        guard model === list else { return }
        if model.index(of: key) != nil {
            model.setCursor(key)
            if selection.pendingCursor == key { selection.pendingCursor = nil }
            cursorFallback = nil
            return
        }
        if model.state != .loading, updates <= 0 {
            if selection.pendingCursor == key {
                selection.pendingCursor = nil
                if let fallback = cursorFallback, fallback != key, model.index(of: fallback) != nil {
                    model.setCursor(fallback)
                }
                cursorFallback = nil
            }
            return
        }
        let wasLoading = model.state == .loading
        withObservationTracking {
            _ = model.revision
            _ = model.state
        } onChange: { [weak self, weak model] in
            Task { @MainActor [weak self, weak model] in
                guard let self, let model, self.selection.pendingCursor == key else { return }
                self.restoreCursor(key, in: model, updates: wasLoading ? updates : updates - 1)
            }
        }
    }

    public func open(_ key: ThreadKey) {
        open(key, marksRead: true)
    }

    private func open(_ key: ThreadKey, marksRead: Bool) {
        readerRestore?.cancel()
        if pendingReaderPlace?.thread != key { pendingReaderPlace = nil }
        noteDetour(opening: key)
        list?.setCursor(key)
        reader?.stop()
        let model = ReaderModel(thread: key, data: environment.data, renderQueue: environment.renderQueue,
                                myAddresses: account.myAddresses)
        if let through = localReads[key] { model.markReadLocally(through: through) }
        if let actions = environment.actions.threadActions {
            model.reportsOnlyArrivals = !marksRead
            model.onShown = { [weak self, weak actions] shown in
                guard let self, let actions else { return }
                if let mark = actions.markReadWhenShown(key, shown: shown, in: self) { self.readMark = mark }
            }
        }
        reader = model
        model.start()
        mode = .reader
    }

    func markReadLocally(_ key: ThreadKey, through date: Date) {
        if let known = localReads[key], known >= date { return }
        localReads[key] = date
        list?.markReadLocally(key, through: date)
        if reader?.thread == key { reader?.markReadLocally(through: date) }
    }

    func pendingReadMark(for keys: [ThreadKey]) -> Task<Void, Never>? {
        guard let thread = reader?.thread, keys.contains(thread) else { return nil }
        reader?.onShown = nil
        return readMark
    }

    func reopenAfterUndo(_ key: ThreadKey) {
        open(key, marksRead: false)
    }

    @discardableResult
    func openCursor() -> Bool {
        guard let key = list?.cursor else { return false }
        open(key)
        return true
    }

    @discardableResult
    func openAdjacent(by delta: Int) -> Bool {
        guard let list else { return false }
        if let current = reader?.thread, list.index(of: current) == nil, let detour, detour.thread == current {
            guard let next = detourNeighbor(detour, by: delta) else { return false }
            open(next)
            return true
        }
        guard list.moveCursor(by: delta) else { return false }
        return openCursor()
    }

    public func closeReader() {
        readerRestore?.cancel()
        pendingReaderPlace = nil
        readerSource = nil
        detour = nil
        reader?.stop()
        reader = nil
        mode = .list
    }

    private func noteDetour(opening key: ThreadKey) {
        guard let list, list.index(of: key) == nil, let cursor = list.cursor else {
            detour = nil
            return
        }
        let reading = mode == .reader ? reader?.thread : nil
        if let detour, reading == detour.thread {
            self.detour = (key, detour.anchor, detour.afterAnchor)
        } else {
            detour = (key, cursor, reading == cursor)
        }
    }

    private func detourNeighbor(_ detour: (thread: ThreadKey, anchor: ThreadKey, afterAnchor: Bool),
                                by delta: Int) -> ThreadKey? {
        guard let list else { return nil }
        let rows = list.rows
        let after: Bool
        let anchor: Int
        if let index = list.index(of: detour.anchor) {
            (anchor, after) = (index, detour.afterAnchor)
        } else if let index = list.cursorIndex {
            (anchor, after) = (index, false)
        } else {
            return nil
        }
        let next = delta > 0 ? (after ? anchor + 1 : anchor) : (after ? anchor : anchor - 1)
        return rows.indices.contains(next) ? rows[next].id : nil
    }

    private func restoreReader(_ key: ThreadKey) {
        open(key, marksRead: false)
        let stream = environment.data.threadDetail(key)
        readerRestore = Task { [weak self] in
            do {
                for try await detail in stream {
                    guard !Task.isCancelled, let self else { return }
                    if detail == nil, self.reader?.thread == key { self.closeReader() }
                    return
                }
            } catch {}
        }
    }

    func attachReader(_ source: any ReaderStateRestorable) {
        readerSource = source
        if let pending = pendingReaderPlace, pending.thread == source.restorableThread {
            pendingReaderPlace = nil
            source.restoreReaderPlace(pending.place)
        }
    }

    func neighbor(of key: ThreadKey) -> ThreadKey? {
        guard let rows = list?.rows, let index = list?.index(of: key) else {
            guard let detour, detour.thread == key else { return nil }
            return detourNeighbor(detour, by: 1) ?? detourNeighbor(detour, by: -1)
        }
        if index + 1 < rows.count { return rows[index + 1].id }
        if index > 0 { return rows[index - 1].id }
        return nil
    }

    func place() -> AccountPlace? {
        guard let location else { return nil }
        let searchText = self.searchText, searchOpen = self.searchOpen
        guard AccountPlace.isRestorable(location) else {
            return lastRestorable.map { AccountPlace(account: id, location: $0, searchText: searchText, searchOpen: searchOpen) }
        }
        let cursor = list?.cursor ?? selection.pendingCursor
        let open = mode == .reader ? reader?.thread : nil
        var readerPlace: ReaderPlace?
        if let open {
            if let source = readerSource, source.restorableThread == open {
                readerPlace = source.captureReaderPlace()
            } else if let pending = pendingReaderPlace, pending.thread == open {
                readerPlace = pending.place
            }
        }
        return AccountPlace(account: id, location: location, cursor: cursor, scrollTop: selection.scrollTop,
                            openThread: open, cursorFallback: cursor.flatMap(neighbor(of:)) ?? cursorFallback,
                            checked: selection.checked.sorted { $0.rowID < $1.rowID },
                            scrollOffset: selection.scrollOffset, reader: readerPlace, searchText: searchText,
                            searchOpen: searchOpen)
    }
}
