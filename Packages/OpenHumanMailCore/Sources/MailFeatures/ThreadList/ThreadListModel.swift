import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class ThreadListModel {
    public enum LoadState: Equatable, Sendable { case loading, loaded, failed(String) }

    public enum Event: Sendable {
        case rows(ThreadListChange)
        case cursor(ThreadKey?)
    }

    public nonisolated static let initialLimit = 100
    public nonisolated static let growth = 200
    public nonisolated static let maximumLiveWindow = 2_000
    public nonisolated static let prefetchDistance = 30
    public nonisolated static let pageSize = 500

    public let location: MailLocation
    public let account: AccountID
    public private(set) var rows: [ThreadRow] = []
    public private(set) var hasMore = false
    public private(set) var totalCount = 0
    public private(set) var optimisticHiddenCount = 0
    public private(set) var placeholderCount = 0
    public private(set) var state: LoadState = .loading
    public private(set) var cursor: ThreadKey?
    public private(set) var revision = 0
    public private(set) var lastChange: ThreadListChange = .reload
    public private(set) var limit = ThreadListModel.initialLimit
    public private(set) var isPagingUnavailable = false
    public private(set) var pagingFailed = false
    public private(set) var selection: SelectionModel
    public private(set) var labels: [Int64: LabelInfo] = [:]
    public private(set) var mutedLabelRowID: Int64?
    public private(set) var impliesImportance = false
    public var groupsByDate = false {
        didSet { if groupsByDate != oldValue { regroup() } }
    }
    public private(set) var groups = ThreadListGroups.none
    @ObservationIgnored public var groupFormatting = ThreadRowFormatting()
    @ObservationIgnored public private(set) var lastKeyAt: Date?
    public private(set) var searchStatus: SearchWindowStatus?

    public var displayCount: Int { rows.count + placeholderCount + groups.count }

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pipeline: ThreadListPipeline?
    @ObservationIgnored private var snapshot = ThreadListSnapshot.empty
    @ObservationIgnored private var displayedToken: Int?
    @ObservationIgnored private var nextLocalToken = -1
    @ObservationIgnored private var overlay = ThreadListOverlay()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var chromeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listeners: [(owner: ObjectIdentifier, handler: @MainActor (Event) -> Void)] = []
    @ObservationIgnored private var labelRowsByGmailID: [GmailLabelID: Int64] = [:]
    @ObservationIgnored private var provisionalLabels: [Int64: LabelInfo] = [:]
    @ObservationIgnored private var provisionalTickets: [OptimisticTicket: Int64] = [:]
    @ObservationIgnored private var nextProvisionalLabel: Int64 = -1
    @ObservationIgnored private var requestedThrough = -1
    @ObservationIgnored private var visiblePages: ClosedRange<Int>?
    @ObservationIgnored public var onInstall: ((ThreadListChange, Duration) -> Void)?

    public init(data: any MailDataSource, location: MailLocation, account: AccountID,
                selection: SelectionModel = SelectionModel(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.data = data
        self.location = location
        self.account = account
        self.selection = selection
        self.now = now
        if location == .system(.important) { impliesImportance = true }
    }

    isolated deinit {
        expiryTask?.cancel()
        for task in chromeTasks { task.cancel() }
    }

    public var cursorIndex: Int? { cursor.flatMap { snapshot.index(of: $0) } }

    public func row(for key: ThreadKey) -> ThreadRow? { snapshot.index(of: key).map { rows[$0] } }

    public func index(of key: ThreadKey) -> Int? { snapshot.index(of: key) }

    public func displayIndex(of key: ThreadKey) -> Int? {
        guard let row = snapshot.index(of: key) else { return nil }
        return groups.displayIndex(ofRow: row)
    }

    public func rowIndex(atDisplay index: Int) -> Int? {
        if case .row(let row) = groups.item(atDisplay: index) { return row }
        return nil
    }

    public func header(atDisplay index: Int) -> ThreadListGroups.Header? {
        if case .header(let header) = groups.item(atDisplay: index) { return groups.headers[header] }
        return nil
    }

    public func rowIndex(atOrAfterDisplay index: Int) -> Int { groups.rowIndex(atOrAfterDisplay: index) }

    public func visibleDisplayRangeDidChange(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        let lower = rowIndex(atOrAfterDisplay: range.lowerBound)
        let upper = max(lower + 1, rowIndex(atOrAfterDisplay: range.upperBound - 1) + 1)
        visibleRangeDidChange(lower..<upper)
    }

    public func regroup() {
        let next = makeGroups(rows)
        guard next != groups else { return }
        groups = next
        lastChange = .reload
        revision += 1
        notify(.rows(.reload))
    }

    private func makeGroups(_ rows: [ThreadRow]) -> ThreadListGroups {
        guard groupsByDate, !location.sortsAscending else { return .none }
        return ThreadListGroups.make(rows: rows, format: groupFormatting, now: now())
    }

    public func addListener(_ owner: AnyObject, _ handler: @escaping @MainActor (Event) -> Void) {
        listeners.removeAll { $0.owner == ObjectIdentifier(owner) }
        listeners.append((ObjectIdentifier(owner), handler))
    }

    public func removeListener(_ owner: AnyObject) {
        listeners.removeAll { $0.owner == ObjectIdentifier(owner) }
    }

    private func notify(_ event: Event) {
        for listener in listeners { listener.handler(event) }
    }

    public func start() {
        if pipeline == nil {
            let deliver: @MainActor @Sendable (ThreadListBuild) -> Void = { [weak self] build in self?.install(build) }
            pipeline = ThreadListPipeline(data: data, location: location, account: account, now: now, deliver: deliver)
        }
        let limit = self.limit
        let pipeline = self.pipeline
        let seed = overlay.localReads.isEmpty ? nil : overlay
        Task {
            if let seed { await pipeline?.seed(seed) }
            await pipeline?.subscribe(limit: limit)
        }
        observeLabels()
    }

    public func stop() {
        let pipeline = self.pipeline
        Task { await pipeline?.stop() }
        for task in chromeTasks { task.cancel() }
        chromeTasks = []
        expiryTask?.cancel()
        expiryTask = nil
    }

    public func attach(selection: SelectionModel) {
        guard selection !== self.selection else { return }
        self.selection = selection
        pruneSelection()
    }

    private func install(_ build: ThreadListBuild) {
        if let failure = build.failure, rows.isEmpty {
            state = .failed(failure)
            return
        }
        let clock = ContinuousClock()
        let start = onInstall == nil ? nil : clock.now
        defer { if let start { onInstall?(build.change, clock.now - start) } }
        isPagingUnavailable = build.pagingUnavailable
        if pagingFailed != build.pagingFailed { pagingFailed = build.pagingFailed }
        if searchStatus != build.searchStatus { searchStatus = build.searchStatus }
        overlay.drop(settled: build.settled)
        var next = build.snapshot
        var change = build.change
        var token: Int? = build.token
        if build.overlayVersion != overlay.version {
            let (rows, hidden) = overlay.apply(to: next.rows)
            next = ThreadListSnapshot(rows: rows, placeholderCount: next.placeholderCount,
                                      totalCount: max(next.totalCount - hidden, rows.count), hasMore: next.hasMore)
            token = nil
            change = Self.localChange(from: snapshot, to: next)
        } else if build.basedOn != displayedToken {
            change = Self.localChange(from: snapshot, to: next)
        }
        show(next, change: change)
        displayedToken = token
        if state != .loaded { state = .loaded }
        scheduleExpiry()
    }

    private static func localChange(from old: ThreadListSnapshot, to new: ThreadListSnapshot) -> ThreadListChange {
        guard old.rows.count <= 5_000, new.rows.count <= 5_000 else { return .reload }
        return ThreadListEdit.between(old, new)
    }

    private func show(_ next: ThreadListSnapshot, change: ThreadListChange) {
        let previous = snapshot
        let previousCursor = cursor
        let previousGroups = groups
        snapshot = next
        rows = next.rows
        defer { releaseOffMain(previous) }
        hasMore = next.hasMore
        totalCount = next.totalCount
        optimisticHiddenCount = overlay.hiddenKeys.count
        placeholderCount = next.placeholderCount
        groups = makeGroups(next.rows)
        cursor = Self.continuedCursor(previousCursor, old: previous, new: next)
        pruneSelection()
        let shown = ThreadListGroups.translate(change, from: previousGroups, to: groups)
        lastChange = shown
        revision += 1
        notify(.rows(shown))
        if cursor != previousCursor { notify(.cursor(cursor)) }
    }

    static func continuedCursor(_ cursor: ThreadKey?, old: ThreadListSnapshot, new: ThreadListSnapshot) -> ThreadKey? {
        guard !new.rows.isEmpty else { return nil }
        guard let cursor else { return new.rows[0].id }
        if new.index(of: cursor) != nil { return cursor }
        guard let oldIndex = old.index(of: cursor) else { return new.rows[0].id }
        var i = oldIndex + 1
        while i < old.rows.count {
            if new.index(of: old.rows[i].id) != nil { return old.rows[i].id }
            i += 1
        }
        i = oldIndex - 1
        while i >= 0 {
            if new.index(of: old.rows[i].id) != nil { return old.rows[i].id }
            i -= 1
        }
        return new.rows[min(oldIndex, new.rows.count - 1)].id
    }

    private func pruneSelection() {
        guard !selection.checked.isEmpty || selection.anchor != nil else { return }
        let present = selection.checked.filter { snapshot.index(of: $0) != nil }
        var keep = Set(present)
        if let anchor = selection.anchor, snapshot.index(of: anchor) != nil { keep.insert(anchor) }
        if present.count != selection.checked.count || (selection.anchor.map { snapshot.index(of: $0) == nil } ?? false) {
            selection.prune(keeping: keep)
        }
    }

    @discardableResult
    public func moveCursor(by delta: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        lastKeyAt = now()
        let current = cursorIndex ?? 0
        let next = min(max(current + delta, 0), rows.count - 1)
        visibleRowsDidChange(lastVisibleIndex: next)
        guard next != current || cursor == nil else { return false }
        setCursorUnchecked(rows[next].id)
        return true
    }

    public func setCursor(_ key: ThreadKey) {
        guard snapshot.index(of: key) != nil, key != cursor else { return }
        setCursorUnchecked(key)
    }

    private func setCursorUnchecked(_ key: ThreadKey) {
        cursor = key
        notify(.cursor(key))
    }

    public func visibleRowsDidChange(lastVisibleIndex: Int) {
        visibleRangeDidChange(max(0, lastVisibleIndex)..<(max(0, lastVisibleIndex) + 1))
    }

    public func visibleRangeDidChange(_ range: Range<Int>) {
        guard let pipeline, !range.isEmpty else { return }
        let needed = range.upperBound - 1
        if hasMore, limit < Self.maximumLiveWindow, needed >= rows.count - Self.prefetchDistance {
            let jump = ((needed + Self.prefetchDistance + Self.growth - 1) / Self.growth) * Self.growth
            limit = min(Self.maximumLiveWindow, max(limit + Self.growth, jump))
            let limit = self.limit
            Task { await pipeline.subscribe(limit: limit) }
        }
        if hasMore, limit >= Self.maximumLiveWindow, needed >= rows.count - Self.prefetchDistance {
            let through = needed + Self.pageSize / 2
            if through > requestedThrough {
                requestedThrough = through
                Task { await pipeline.requestRows(through: through) }
            }
        }
        if limit >= Self.maximumLiveWindow {
            let pages = (range.lowerBound / Self.pageSize)...((range.upperBound - 1) / Self.pageSize)
            if pages != visiblePages {
                visiblePages = pages
                Task { await pipeline.refreshPages(visible: range) }
            }
        }
    }

    public func retryPaging() {
        guard pagingFailed, let pipeline else { return }
        Task { await pipeline.retry() }
    }

    @discardableResult
    public func applyOptimistic(_ command: MailCommand) -> OptimisticTicket? {
        applyEffect(OptimisticEffect.of(command, in: location, labelRows: labelRowsByGmailID))
    }

    @discardableResult
    public func applyOptimisticLabel(named name: String, to keys: [ThreadKey]) -> OptimisticTicket? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !keys.isEmpty else { return nil }
        let effect = { (id: Int64) in
            OptimisticEffect(patches: Dictionary(keys.map { ($0, RowPatch(addUserLabels: [id])) },
                                                 uniquingKeysWith: { $1 }))
        }
        if let known = labels.values.first(where: { $0.kind == .user && $0.name == name }) {
            return applyEffect(effect(known.id))
        }
        let id = nextProvisionalLabel
        nextProvisionalLabel -= 1
        let label = LabelInfo(id: id, account: account, labelID: GmailLabelID("oh:provisional:\(-id)"), kind: .user,
                              name: name, displayName: String(name.split(separator: "/").last ?? Substring(name)),
                              position: Int.max)
        provisionalLabels[id] = label
        labels[id] = label
        guard let ticket = applyEffect(effect(id)) else {
            provisionalLabels[id] = nil
            labels[id] = nil
            return nil
        }
        provisionalTickets[ticket] = id
        return ticket
    }

    private func applyEffect(_ effect: OptimisticEffect) -> OptimisticTicket? {
        guard !effect.isEmpty else { return nil }
        lastKeyAt = now()
        let present = effect.keys.filter { snapshot.index(of: $0) != nil }
        guard !present.isEmpty, let ticket = overlay.add(effect, at: now()) else { return nil }
        var next = snapshot
        let removed = next.remove(effect.hidden)
        var reconfigured = IndexSet()
        for key in effect.patches.keys {
            guard let i = next.index(of: key), let patch = overlay.patch(for: key) else { continue }
            next.rows[i] = patch.applied(to: next.rows[i])
            reconfigured.insert(i)
        }
        next.totalCount = max(next.totalCount - removed.count, next.rows.count)
        localEdit(next, change: .update(ThreadListEdit(removed: removed, reconfigured: reconfigured)),
                  changedKeys: effect.keys)
        scheduleExpiry()
        return ticket
    }

    public func revertOptimistic(_ ticket: OptimisticTicket) {
        if let id = provisionalTickets.removeValue(forKey: ticket), provisionalLabels.removeValue(forKey: id) != nil {
            labels[id] = nil
        }
        guard overlay.revert(ticket) else { return }
        pushOverlay(changedKeys: [])
    }

    public func clearOptimistic(for keys: Set<ThreadKey>) {
        guard overlay.clear(keys: keys) else { return }
        pushOverlay(changedKeys: keys)
    }

    public func expireOptimistic(now date: Date) {
        guard overlay.expire(now: date) else { return }
        pushOverlay(changedKeys: [])
    }

    public var optimisticKeys: Set<ThreadKey> { overlay.touchedKeys }

    public func markReadLocally(_ key: ThreadKey, through date: Date) {
        guard overlay.markReadLocally(key, through: date) else { return }
        guard let i = snapshot.index(of: key) else {
            if state != .loading { pushOverlay(changedKeys: [key]) }
            return
        }
        var next = snapshot
        next.rows[i] = overlay.locallyRead(next.rows[i])
        localEdit(next, change: .update(ThreadListEdit(reconfigured: IndexSet(integer: i))), changedKeys: [key])
    }

    public func seedLocalReads(_ reads: [ThreadKey: Date]) {
        var changed: Set<ThreadKey> = []
        for (key, date) in reads where overlay.markReadLocally(key, through: date) { changed.insert(key) }
        guard !changed.isEmpty, pipeline != nil else { return }
        pushOverlay(changedKeys: changed)
    }

    private func localEdit(_ next: ThreadListSnapshot, change: ThreadListChange, changedKeys: Set<ThreadKey>) {
        show(next, change: change)
        let token = nextLocalToken
        nextLocalToken -= 1
        displayedToken = token
        pushOverlay(changedKeys: changedKeys, displayed: next, token: token)
    }

    private func pushOverlay(changedKeys: Set<ThreadKey>, displayed: ThreadListSnapshot? = nil, token: Int? = nil) {
        let overlay = self.overlay
        let pipeline = self.pipeline
        Task { await pipeline?.setOverlay(overlay, displayed: displayed, token: token, changedKeys: changedKeys) }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let expiry = overlay.earliestExpiry else {
            expiryTask = nil
            return
        }
        let delay = max(0, expiry.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expireOptimistic(now: self.now())
            self.scheduleExpiry()
        }
    }

    private func observeLabels() {
        guard chromeTasks.isEmpty else { return }
        let data = self.data, account = self.account
        chromeTasks.append(Task.detached { [weak self] in
            do {
                for try await labels in data.labels(account) {
                    guard !Task.isCancelled else { return }
                    await self?.applyLabels(labels)
                }
            } catch {}
        })
        if case .split(let key) = location {
            chromeTasks.append(Task.detached { [weak self] in
                do {
                    for try await splits in data.splits(account) {
                        guard !Task.isCancelled else { return }
                        let rule = splits.first { $0.id == key }?.ruleText ?? ""
                        await self?.applyImportance(ThreadRowFormatting.ruleImpliesImportance(rule))
                    }
                } catch {}
            })
        }
    }

    private func applyImportance(_ implies: Bool) {
        if impliesImportance != implies { impliesImportance = implies }
    }

    private func applyLabels(_ list: [LabelInfo]) {
        var byID: [Int64: LabelInfo] = [:]
        var byGmail: [GmailLabelID: Int64] = [:]
        for label in list where label.kind == .user || label.kind == .category {
            byID[label.id] = LabelInfo(id: label.id, account: label.account, labelID: label.labelID, kind: label.kind,
                                       name: label.name, displayName: label.displayName,
                                       colorBackground: label.colorBackground, colorText: label.colorText,
                                       isHidden: label.isHidden, position: label.position)
            byGmail[label.labelID] = label.id
        }
        labelRowsByGmailID = byGmail
        let muted = list.first { $0.name == OHGmailLabels.muted }?.id
        if muted != mutedLabelRowID { mutedLabelRowID = muted }
        var swaps: [Int64: Int64] = [:]
        for (id, label) in provisionalLabels {
            let stored = byID.values.first { $0.kind == .user && $0.name == label.name }
            if let stored { swaps[id] = stored.id }
        }
        for id in swaps.keys { provisionalLabels[id] = nil }
        if !swaps.isEmpty { provisionalTickets = provisionalTickets.filter { provisionalLabels[$0.value] != nil } }
        let shown = byID.merging(provisionalLabels) { stored, _ in stored }
        if shown != labels { labels = shown }
        handOver(swaps)
    }

    private func handOver(_ swaps: [Int64: Int64]) {
        let touched = overlay.relabel(swaps)
        guard !touched.isEmpty else { return }
        var next = snapshot
        var reconfigured = IndexSet()
        for key in touched {
            guard let i = next.index(of: key) else { continue }
            var ids: [Int64] = []
            for id in next.rows[i].userLabelIDs.map({ swaps[$0] ?? $0 }) where !ids.contains(id) { ids.append(id) }
            next.rows[i] = next.rows[i].replacing(userLabelIDs: ids)
            reconfigured.insert(i)
        }
        if reconfigured.isEmpty {
            pushOverlay(changedKeys: touched)
        } else {
            localEdit(next, change: .update(ThreadListEdit(reconfigured: reconfigured)), changedKeys: touched)
        }
    }

    public func isMuted(_ row: ThreadRow) -> Bool {
        guard let id = mutedLabelRowID else { return false }
        return row.userLabelIDs.contains(id)
    }

    public func chips(for row: ThreadRow) -> [ThreadRowChip] {
        var chips = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(
            location: location, labels: labels, impliesImportance: impliesImportance,
            superhuman: superhumanLabels?.rules ?? SuperhumanLabelRules()),
                                              autoLabel: autoLabels?.title(for: row, labels: labels))
        if let vips, vips.hasVIPSender(row) { chips.insert(ThreadRowChip(kind: .vip, title: VIPCenter.chipTitle), at: 0) }
        return chips
    }

    @ObservationIgnored public private(set) weak var vips: VIPCenter?

    public func attachVIPs(_ center: VIPCenter?) {
        vips = center
        observeVIPs()
    }

    private func observeVIPs() {
        guard let center = vips else { return }
        withObservationTracking {
            _ = center.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chipRevision += 1
                self.observeVIPs()
            }
        }
    }

    @ObservationIgnored public private(set) weak var autoLabels: AutoLabelCenter?
    public private(set) var chipRevision = 0

    public func attachAutoLabels(_ center: AutoLabelCenter?) {
        autoLabels = center
        observeAutoLabels()
    }

    @ObservationIgnored public private(set) weak var superhumanLabels: SuperhumanLabelDisplay?

    public func attachSuperhumanLabels(_ display: SuperhumanLabelDisplay?) {
        superhumanLabels = display
        observeSuperhumanLabels()
    }

    private func observeSuperhumanLabels() {
        guard let display = superhumanLabels else { return }
        withObservationTracking {
            _ = display.rules
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chipRevision += 1
                self.observeSuperhumanLabels()
            }
        }
    }

    private func observeAutoLabels() {
        guard let center = autoLabels else { return }
        withObservationTracking {
            _ = center.revision
            _ = center.isOn
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chipRevision += 1
                self.observeAutoLabels()
            }
        }
    }
}
