import Foundation
import MailModel
import OpenHumanCore

struct ThreadListBuild: Sendable {
    let token: Int
    let basedOn: Int
    let snapshot: ThreadListSnapshot
    let change: ThreadListChange
    let overlayVersion: Int
    let settled: [Int]
    let pagingUnavailable: Bool
    let pagingFailed: Bool
    let failure: String?
    let searchStatus: SearchWindowStatus?
}

actor ThreadListPipeline {
    private let data: any MailDataSource
    private let location: MailLocation
    private let account: AccountID
    private let deliver: @MainActor @Sendable (ThreadListBuild) -> Void
    private let now: @Sendable () -> Date
    private var assembler: ThreadListAssembler
    private var liveTask: Task<Void, Never>?
    private var liveLimit = 0
    private var pendingWindow: ThreadListWindow?
    private var pendingSettled: [Int] = []
    private var settledIDs = Set<Int>()
    private var pendingFailure: String?
    private var searchStatus: SearchWindowStatus?
    private var needsBuild = false
    private var draining = false
    private var token = 0
    private var basedOn = 0
    private var liveGeneration = 0
    private var requestedThrough = -1
    private var fetching = false
    private var pagingFailed = false
    private var liveFailed = false
    private var refreshing = Set<Int>()

    static let minimumRefreshInterval: TimeInterval = 2
    static let maximumPageAge: TimeInterval = 30
    static let refreshSlack = 50

    init(data: any MailDataSource, location: MailLocation, account: AccountID, now: @escaping @Sendable () -> Date,
         deliver: @escaping @MainActor @Sendable (ThreadListBuild) -> Void) {
        self.data = data
        self.location = location
        self.account = account
        self.now = now
        self.deliver = deliver
        self.assembler = ThreadListAssembler(sortsAscending: location.sortsAscending)
    }

    deinit {
        liveTask?.cancel()
    }

    func subscribe(limit: Int) {
        guard limit > liveLimit || liveTask == nil else { return }
        liveTask?.cancel()
        liveLimit = limit
        let stream = data.threadWindow(location, account: account, limit: limit)
        liveTask = Task { [weak self] in
            do {
                for try await window in stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.receive(window)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                await self?.fail(error)
            }
        }
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
    }

    func retry() {
        pagingFailed = false
        if liveFailed {
            liveFailed = false
            let limit = liveLimit
            liveLimit = 0
            subscribe(limit: limit)
        }
        scheduleBuild()
        fetchIfNeeded()
    }

    func receive(_ window: ThreadListWindow) {
        liveGeneration += 1
        liveFailed = false
        if !assembler.overlay.isEmpty {
            let touched = assembler.overlay.touchedKeys
            var present: [ThreadKey: ThreadRow] = [:]
            for row in window.rows where touched.contains(row.id) { present[row.id] = row }
            for page in assembler.pages {
                for row in page.rows where touched.contains(row.id) && present[row.id] == nil { present[row.id] = row }
            }
            let settled = assembler.overlay.confirm { present[$0] }
            settledIDs.formUnion(settled)
            pendingSettled += settled
        }
        pendingWindow = window
        scheduleBuild()
    }

    private func fail(_ error: any Error) {
        liveFailed = true
        pendingFailure = String(describing: error)
        scheduleBuild()
    }

    func seed(_ overlay: ThreadListOverlay) {
        assembler.overlay = overlay
    }

    func setOverlay(_ overlay: ThreadListOverlay, displayed: ThreadListSnapshot?, token displayedToken: Int?,
                    changedKeys: Set<ThreadKey>) {
        assembler.overlay = overlay
        if !settledIDs.isEmpty { assembler.overlay.drop(settled: Array(settledIDs)) }
        if let displayed, let displayedToken {
            assembler.previous = displayed
            basedOn = displayedToken
        }
        assembler.dirtyKeys.formUnion(changedKeys)
        let touched = overlay.touchedKeys.union(changedKeys)
        if !touched.isEmpty {
            for (k, page) in assembler.pages.enumerated() where page.rows.contains(where: { touched.contains($0.id) }) {
                startRefresh(k)
            }
        }
        scheduleBuild()
    }

    func requestRows(through index: Int) {
        requestedThrough = max(requestedThrough, index)
        fetchIfNeeded()
    }

    private func fetchIfNeeded() {
        guard !fetching, !pagingFailed, assembler.liveHasMore, !assembler.pagingFinished, !assembler.pagingUnavailable,
              liveLimit >= ThreadListModel.maximumLiveWindow, loadedEstimate <= requestedThrough else { return }
        fetching = true
        Task { await self.fetchPages() }
    }

    private var loadedEstimate: Int {
        max(assembler.live.count, assembler.pages.reduce(0) { $0 + $1.rows.count })
    }

    private func fetchPages() async {
        defer { fetching = false }
        var pagesSinceBuild = 0
        while assembler.liveHasMore, !assembler.pagingFinished, !assembler.pagingUnavailable, !pagingFailed,
              loadedEstimate <= requestedThrough {
            let after = assembler.pages.last?.next
            if !assembler.pages.isEmpty, after == nil { assembler.pagingFinished = true; break }
            let generation = liveGeneration
            do {
                let result = try await data.threadPage(location, account: account, after: after,
                                                       limit: ThreadListModel.pageSize)
                assembler.pages.append(ThreadListPage(after: after, rows: result.rows, next: result.next,
                                                      generation: generation, fetchedAt: now()))
                if result.next == nil || result.rows.isEmpty { assembler.pagingFinished = true }
            } catch {
                if let port = error as? MailPortError, case .unsupported = port {
                    assembler.pagingUnavailable = true
                } else if !(error is CancellationError) {
                    pagingFailed = true
                }
            }
            pagesSinceBuild += 1
            if pagesSinceBuild >= 4 {
                pagesSinceBuild = 0
                scheduleBuild()
            }
        }
        scheduleBuild()
    }

    func refreshPages(visible range: Range<Int>) {
        guard !assembler.pages.isEmpty, !range.isEmpty else { return }
        let size = ThreadListModel.pageSize
        let first = max(0, range.lowerBound / size), last = min(assembler.pages.count - 1, (range.upperBound - 1) / size)
        guard first <= last else { return }
        let current = now()
        for k in first...last {
            let page = assembler.pages[k]
            let age = current.timeIntervalSince(page.fetchedAt)
            guard (k + 1) * size > assembler.live.count, page.generation < liveGeneration || age >= Self.maximumPageAge,
                  age >= Self.minimumRefreshInterval else { continue }
            startRefresh(k)
        }
    }

    private func startRefresh(_ k: Int) {
        guard !refreshing.contains(k) else { return }
        refreshing.insert(k)
        Task { await self.refresh(k) }
    }

    private func refresh(_ k: Int) async {
        defer { refreshing.remove(k) }
        guard k < assembler.pages.count else { return }
        let after = assembler.pages[k].after
        let generation = liveGeneration
        guard let result = try? await data.threadPage(location, account: account, after: after,
                                                      limit: ThreadListModel.pageSize + Self.refreshSlack),
              k < assembler.pages.count, assembler.pages[k].after == after else { return }
        assembler.dirtyKeys.formUnion(assembler.pages[k].rows.map(\.id))
        assembler.dirtyKeys.formUnion(result.rows.map(\.id))
        assembler.pages[k].rows = result.rows
        assembler.pages[k].generation = generation
        assembler.pages[k].fetchedAt = now()
        scheduleBuild()
    }

    private func scheduleBuild() {
        needsBuild = true
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while needsBuild {
            needsBuild = false
            if let window = pendingWindow {
                pendingWindow = nil
                assembler.live = window.rows
                assembler.liveTotal = window.totalCount
                assembler.liveHasMore = window.hasMore
                searchStatus = window.search
                if !window.hasMore {
                    assembler.pages = []
                    assembler.pagingFinished = false
                }
            }
            let (snapshot, change, settled) = assembler.assemble()
            settledIDs.formUnion(settled)
            token += 1
            let build = ThreadListBuild(token: token, basedOn: basedOn, snapshot: snapshot, change: change,
                                        overlayVersion: assembler.overlay.version, settled: pendingSettled + settled,
                                        pagingUnavailable: assembler.pagingUnavailable,
                                        pagingFailed: (pagingFailed || liveFailed) && !assembler.pagingUnavailable, failure: pendingFailure,
                                        searchStatus: searchStatus)
            basedOn = token
            pendingSettled = []
            pendingFailure = nil
            await deliver(build)
            fetchIfNeeded()
        }
        draining = false
    }
}
