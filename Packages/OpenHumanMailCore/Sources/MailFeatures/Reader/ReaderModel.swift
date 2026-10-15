import Foundation
import MailModel
import MailRender
import Observation

@MainActor
@Observable
public final class ReaderModel {
    public enum LoadState: Equatable, Sendable { case loading, loaded, missing, failed(String) }

    public enum BodyState: Equatable, Sendable {
        case notLoaded
        case fetching
        case rendered(RenderedBody)
        case failed(String)
    }

    public struct Message: Identifiable, Equatable, Sendable {
        public var id: MessageKey { summary.id }
        public let summary: MessageSummary
        public var isExpanded: Bool
        public var body: BodyState
        public var imagesShown: RemoteContentPolicy.Source?
        public var colorOverride: ColorOverride?
        public var quotesExpanded: Bool
        public var accessory: ReaderHeaderAccessoryItem?
    }

    public enum Item: Hashable, Sendable {
        case message(MessageKey)
        case olderMessages([MessageKey])
    }

    public let thread: ThreadKey
    public private(set) var subject = ""
    public private(set) var isStarred = false
    public private(set) var userLabelIDs: [Int64] = []
    public private(set) var messages: [Message] = []
    public private(set) var state: LoadState = .loading
    public private(set) var revision = 0
    public private(set) var focusedMessage: MessageKey?
    public private(set) var focusChosen = false
    public private(set) var focusScrollRequest = 0
    public private(set) var findRequest = 0
    public private(set) var showsAllMessages = false
    public private(set) var imagePolicy: RemoteImagePolicy = .block
    public private(set) var allowedSenders: [String] = []
    public private(set) var colorOverrides: [String: String] = [:]
    public private(set) var notice: String?
    public internal(set) var quoteSelection: QuoteSelection?
    public let safeMode: SafeModeInfo
    public private(set) var pendingMessages: [MessageKey] = []
    @ObservationIgnored public private(set) var hasInteracted = false
    public let myAddresses: Set<String>
    public private(set) var localReadThrough: Date?
    @ObservationIgnored var onShown: (@MainActor ([MessageSummary]) -> Void)?
    @ObservationIgnored var reportsOnlyArrivals = false
    @ObservationIgnored private var reportedShown: Set<MessageKey>?

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let renderQueue: RenderQueue
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var bodyTasks: [MessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var renderTasks: [MessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var accessoryTasks: [MessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var settingsTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var contents: [MessageKey: MessageContent] = [:]
    @ObservationIgnored private var renderedWith: [MessageKey: RenderCacheKey] = [:]
    @ObservationIgnored private var expansionOverrides: [MessageKey: Bool] = [:]
    @ObservationIgnored private var quoteState: Set<MessageKey> = []
    @ObservationIgnored private var originalSpacing: Set<MessageKey> = []
    @ObservationIgnored private var loadOnce: Set<MessageKey> = []
    @ObservationIgnored private var settingsSeen: Set<Int> = []
    @ObservationIgnored private var settingsReady = false
    @ObservationIgnored private var accessoryAsked: Set<MessageKey> = []
    @ObservationIgnored private var latest: [MessageSummary] = []

    @ObservationIgnored private let accessorySlot: ReaderHeaderAccessoryStore

    public init(thread: ThreadKey, data: any MailDataSource, renderQueue: RenderQueue, myAddresses: Set<String> = [],
                accessorySlot: ReaderHeaderAccessoryStore = ReaderHeaderAccessorySlot.shared) {
        self.accessorySlot = accessorySlot
        self.thread = thread
        self.data = data
        self.renderQueue = renderQueue
        self.settings = renderQueue.settings
        self.safeMode = data.safeMode()
        self.myAddresses = Set(myAddresses.map { $0.lowercased() })
    }

    isolated deinit {
        cancelAll()
    }

    public func start() {
        detailTask?.cancel()
        observeSettings()
        let stream = data.threadDetail(thread)
        detailTask = Task { [weak self] in
            do {
                for try await detail in stream {
                    guard !Task.isCancelled else { return }
                    self?.apply(detail)
                }
            } catch is CancellationError {
            } catch {
                self?.state = .failed(String(describing: error))
                self?.revision += 1
            }
        }
    }

    public func stop() {
        onShown = nil
        cancelAll()
    }

    private func cancelAll() {
        detailTask?.cancel()
        detailTask = nil
        for task in Array(bodyTasks.values) + Array(renderTasks.values) + Array(accessoryTasks.values) + settingsTasks {
            task.cancel()
        }
        bodyTasks = [:]
        renderTasks = [:]
        accessoryTasks = [:]
        settingsTasks = []
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    public func message(_ key: MessageKey) -> Message? { messages.first { $0.id == key } }

    public var replyTarget: MessageKey? {
        if focusChosen, let focusedMessage, messages.contains(where: { $0.id == focusedMessage }) { return focusedMessage }
        return messages.last?.id
    }

    public var items: [Item] {
        guard !showsAllMessages else { return messages.map { .message($0.id) } }
        var out: [Item] = []
        var run: [MessageKey] = []
        func flush() {
            if run.count > 3 {
                out.append(.message(run[0]))
                out.append(.olderMessages(Array(run[1..<(run.count - 1)])))
                out.append(.message(run[run.count - 1]))
            } else {
                out += run.map { .message($0) }
            }
            run = []
        }
        for message in messages {
            if message.isExpanded {
                flush()
                out.append(.message(message.id))
            } else {
                run.append(message.id)
            }
        }
        flush()
        return out
    }

    public func showAllMessages() {
        hasInteracted = true
        guard !showsAllMessages else { return }
        showsAllMessages = true
        revision += 1
    }

    public func toggle(_ key: MessageKey) {
        guard let i = messages.firstIndex(where: { $0.id == key }) else { return }
        setExpanded(i, !messages[i].isExpanded)
        focusedMessage = key
        focusChosen = true
        hasInteracted = true
        revision += 1
    }

    public func toggleFocused() {
        guard let focusedMessage else { return }
        toggle(focusedMessage)
    }

    public func expandAll() {
        hasInteracted = true
        for i in messages.indices where !messages[i].isExpanded { setExpanded(i, true) }
        showsAllMessages = true
        revision += 1
    }

    private func setExpanded(_ i: Int, _ expanded: Bool) {
        let key = messages[i].id
        expansionOverrides[key] = expanded
        messages[i].isExpanded = expanded
        if expanded {
            observeBody(key)
            loadAccessory(key)
        }
    }

    public func focus(_ key: MessageKey) {
        guard messages.contains(where: { $0.id == key }) else { return }
        focusChosen = true
        hasInteracted = true
        guard focusedMessage != key else { return }
        focusedMessage = key
        revealFocused()
        revision += 1
    }

    public func reveal(_ key: MessageKey) {
        guard let i = messages.firstIndex(where: { $0.id == key }) else { return }
        var changed = false
        if !messages[i].isExpanded {
            setExpanded(i, true)
            changed = true
        }
        let folded = items.contains { item in
            if case .olderMessages(let keys) = item { return keys.contains(key) }
            return false
        }
        if folded {
            showsAllMessages = true
            changed = true
        }
        if changed { revision += 1 }
    }

    @discardableResult
    public func focusAndReveal(_ key: MessageKey) -> Bool {
        guard messages.contains(where: { $0.id == key }) else { return false }
        reveal(key)
        focusChosen = true
        hasInteracted = true
        focusedMessage = key
        focusScrollRequest += 1
        revision += 1
        return true
    }

    @discardableResult
    public func focusNext() -> Bool { moveFocus(by: 1) }

    @discardableResult
    public func focusPrevious() -> Bool { moveFocus(by: -1) }

    public var canFocusNext: Bool { focusIndex.map { $0 < messages.count - 1 } ?? !messages.isEmpty }

    public var canFocusPrevious: Bool { focusIndex.map { $0 > 0 } ?? !messages.isEmpty }

    private var focusIndex: Int? { focusedMessage.flatMap { key in messages.firstIndex { $0.id == key } } }

    private func moveFocus(by delta: Int) -> Bool {
        guard !messages.isEmpty else { return false }
        let current = focusIndex ?? (delta > 0 ? -1 : messages.count)
        let next = min(max(current + delta, 0), messages.count - 1)
        guard next != current else { return false }
        focusChosen = true
        hasInteracted = true
        focusedMessage = messages[next].id
        revealFocused()
        focusScrollRequest += 1
        revision += 1
        return true
    }

    private func revealFocused() {
        guard let focusedMessage, !showsAllMessages else { return }
        let folded = items.contains { item in
            if case .olderMessages(let keys) = item { return keys.contains(focusedMessage) }
            return false
        }
        if folded { showsAllMessages = true }
    }

    public func requestFind() {
        findRequest += 1
    }

    public func noteInteraction() {
        hasInteracted = true
    }

    public func showNewMessages() {
        guard let newest = pendingMessages.last else { return }
        hasInteracted = true
        for key in pendingMessages { expansionOverrides[key] = true }
        pendingMessages = []
        show(latest)
        focusedMessage = newest
        focusChosen = true
        focusScrollRequest += 1
        revision += 1
        reportShown()
    }

    private func isMine(_ summary: MessageSummary) -> Bool {
        summary.from.map { myAddresses.contains($0.email.lowercased()) } ?? false
    }

    public func toggleQuotedText(_ key: MessageKey? = nil) {
        guard let key = key ?? focusedMessage, let i = messages.firstIndex(where: { $0.id == key }) else { return }
        hasInteracted = true
        if quoteState.contains(key) { quoteState.remove(key) } else { quoteState.insert(key) }
        messages[i].quotesExpanded = quoteState.contains(key)
        revision += 1
    }

    public func imageDecision(_ key: MessageKey) -> (RemoteImageRules.Decision, RemoteContentPolicy.Source?) {
        let sender = message(key)?.summary.from?.email
        return RemoteContentPolicy.decision(policy: imagePolicy, allowedSenders: allowedSenders, sender: sender,
                                            loadOnce: loadOnce.contains(key))
    }

    public func loadImagesOnce(_ key: MessageKey) {
        guard !loadOnce.contains(key) else { return }
        loadOnce.insert(key)
        refreshDerived()
        render(key)
    }

    public func toggleOriginalSpacing(_ key: MessageKey) {
        if originalSpacing.contains(key) { originalSpacing.remove(key) } else { originalSpacing.insert(key) }
        render(key)
    }

    public func keepsOriginalSpacing(_ key: MessageKey) -> Bool { originalSpacing.contains(key) }

    public func hideImages(_ key: MessageKey) {
        guard loadOnce.remove(key) != nil else { return }
        refreshDerived()
        render(key)
    }

    public func showImages() {
        let blocked = blockedImageMessages
        let targets = focusedMessage.map { blocked.contains($0) ? [$0] : blocked } ?? blocked
        for key in targets { loadImagesOnce(key) }
    }

    public var canShowImages: Bool { !blockedImageMessages.isEmpty }

    private var blockedImageMessages: [MessageKey] {
        messages.filter { message in
            guard message.isExpanded, message.imagesShown == nil,
                  case .rendered(.html(let rendered)) = message.body else { return false }
            return rendered.hasRemoteContent
        }.map(\.id)
    }

    public func alwaysEntry(for key: MessageKey) -> String? {
        message(key)?.summary.from.flatMap { RemoteContentPolicy.alwaysEntry(forSender: $0.email) }
    }

    public var remembersChoices: Bool { settings != nil }

    public func alwaysLoadImages(_ key: MessageKey) async {
        guard let entry = alwaysEntry(for: key) else { return }
        await updateAllowlist(RemoteContentPolicy.adding(entry, to: allowedSenders))
    }

    public func stopAlwaysLoadingImages(_ key: MessageKey) async {
        guard let sender = message(key)?.summary.from?.email else { return }
        loadOnce.remove(key)
        await updateAllowlist(RemoteContentPolicy.removingEntries(for: sender, from: allowedSenders))
    }

    private func updateAllowlist(_ list: [String]) async {
        let previous = allowedSenders
        guard list != previous else { return }
        allowedSenders = list
        settingsChanged()
        guard let settings else { return }
        do {
            try await settings.set(AppSettings.remoteImageSenders(thread.account), list)
        } catch {
            allowedSenders = previous
            settingsChanged()
            report("Couldn't save the image setting")
        }
    }

    public func setColorOverride(_ choice: ColorOverride?, for key: MessageKey) async {
        guard let sender = message(key)?.summary.from?.email else { return }
        let previous = colorOverrides
        let updated = RemoteContentPolicy.setting(choice, forSender: sender, in: previous)
        guard updated != previous else { return }
        colorOverrides = updated
        settingsChanged()
        guard let settings else { return }
        do {
            try await settings.set(ReaderSettings.colorOverrides(thread.account), updated)
        } catch {
            colorOverrides = previous
            settingsChanged()
            report("Couldn't save the color choice")
        }
    }

    public func useRenderer(_ renderer: MessageRenderer) {
        if !Self.rendersAlike(renderQueue.renderer, renderer) { renderQueue.setRenderer(renderer) }
        rendererChanged()
    }

    nonisolated static func rendersAlike(_ a: MessageRenderer, _ b: MessageRenderer) -> Bool {
        a.appearance == b.appearance && a.emailColors == b.emailColors && a.underlineLinks == b.underlineLinks
            && a.options == b.options && a.theme == b.theme
    }

    public func rendererChanged() {
        for message in messages where message.isExpanded { render(message.id) }
    }

    public func activateAccessory(_ key: MessageKey) {
        guard let message = message(key), let item = message.accessory,
              let accessory = accessorySlot.current else { return }
        accessory.activate(item, for: message.summary, in: thread)
    }

    private func loadAccessory(_ key: MessageKey) {
        guard let accessory = accessorySlot.current, !accessoryAsked.contains(key),
              let summary = message(key)?.summary else { return }
        accessoryAsked.insert(key)
        let thread = thread
        accessoryTasks[key] = Task { [weak self] in
            let item = await accessory.item(for: summary, in: thread)
            guard !Task.isCancelled, let self, let i = self.messages.firstIndex(where: { $0.id == key }) else { return }
            self.accessoryTasks[key] = nil
            guard self.messages[i].accessory != item else { return }
            self.messages[i].accessory = item
            self.revision += 1
        }
    }

    public func attachmentFile(_ attachment: AttachmentInfo, of key: MessageKey) async throws -> URL {
        let url = try await data.attachmentData(key, attachment: attachment)
        try await Task.detached(priority: .userInitiated) { try AttachmentFiles.ensureQuarantine(url) }.value
        return url
    }

    @discardableResult
    public func saveAttachment(_ attachment: AttachmentInfo, of key: MessageKey, to destination: URL) async throws -> URL {
        let source = try await attachmentFile(attachment, of: key)
        let name = attachment.filename
        return try await Task.detached(priority: .userInitiated) {
            try AttachmentFiles.save(source, filename: name, to: destination)
        }.value
    }

    public func report(_ message: String) {
        notice = message
        revision += 1
    }

    public func clearNotice() {
        notice = nil
    }

    public func prefetch(_ threads: [ThreadKey]) {
        prefetchTask?.cancel()
        let threads = threads.filter { $0 != thread }
        guard !threads.isEmpty else { return }
        let data = data
        let queue = renderQueue
        let policy = imagePolicy
        let allowed = allowedSenders
        let overrides = colorOverrides
        prefetchTask = Task(priority: .utility) {
            for key in threads {
                guard !Task.isCancelled else { return }
                await Self.prefetch(key, data: data, queue: queue, policy: policy, allowed: allowed, overrides: overrides)
            }
        }
    }

    private nonisolated static func prefetch(_ key: ThreadKey, data: any MailDataSource, queue: RenderQueue,
                                             policy: RemoteImagePolicy, allowed: [String], overrides: [String: String]) async {
        guard let detail = try? await first(of: data.threadDetail(key)), let detail else { return }
        let last = detail.messages.last?.id
        for summary in detail.messages where summary.isUnread || summary.id == last {
            guard !Task.isCancelled else { return }
            guard case .available(let content)? = try? await firstAvailable(of: data.body(summary.id)) else { continue }
            let (decision, _) = RemoteContentPolicy.decision(policy: policy, allowedSenders: allowed,
                                                             sender: summary.from?.email, loadOnce: false)
            let context = RenderContext(allowRemoteImages: decision == .load,
                                        colorOverride: RemoteContentPolicy.colorOverride(forSender: summary.from?.email, in: overrides),
                                        textFormat: plainTextFormat(content.textFormat))
            _ = await queue.renderUnlessCancelled(content, for: summary.id, context: context)
        }
    }

    private nonisolated static func first<T: Sendable>(of stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    private nonisolated static func firstAvailable(of stream: AsyncThrowingStream<BodyLoadState, Error>) async throws -> BodyLoadState? {
        for try await value in stream {
            if case .fetching = value { continue }
            return value
        }
        return nil
    }

    func apply(_ detail: ConversationDetail?) {
        guard let detail else {
            state = .missing
            messages = []
            pendingMessages = []
            latest = []
            revision += 1
            return
        }
        subject = detail.subject
        isStarred = detail.isStarred
        userLabelIDs = detail.userLabelIDs
        var held = Set(pendingMessages)
        if state == .loaded, hasInteracted {
            let known = held.union(messages.map(\.id))
            for summary in detail.messages where !known.contains(summary.id) && !isMine(summary) { held.insert(summary.id) }
        }
        pendingMessages = detail.messages.map(\.id).filter(held.contains)
        latest = locallyRead(detail.messages)
        show(latest)
        reportShown()
    }

    private func reportShown() {
        guard let onShown else { return }
        let shown = messages.map(\.summary)
        guard let reported = reportedShown else {
            reportedShown = Set(shown.map(\.id))
            if !reportsOnlyArrivals { onShown(shown) }
            return
        }
        let fresh = shown.filter { !reported.contains($0.id) }
        guard !fresh.isEmpty else { return }
        reportedShown = reported.union(fresh.map(\.id))
        guard pendingMessages.isEmpty, fresh.contains(where: { $0.isUnread && !isMine($0) }) else { return }
        onShown(shown)
    }

    public func markReadLocally(through date: Date) {
        guard localReadThrough.map({ $0 < date }) ?? true else { return }
        localReadThrough = date
        guard state == .loaded else { return }
        latest = locallyRead(latest)
        show(latest)
    }

    private func locallyRead(_ summaries: [MessageSummary]) -> [MessageSummary] {
        guard let through = localReadThrough else { return summaries }
        return summaries.map { s in
            guard s.isUnread, s.date <= through else { return s }
            return MessageSummary(id: s.id, from: s.from, to: s.to, cc: s.cc, bcc: s.bcc, date: s.date, snippet: s.snippet,
                                  isUnread: false, attachments: s.attachments, hasCalendarInvite: s.hasCalendarInvite)
        }
    }

    private func show(_ summaries: [MessageSummary]) {
        let held = Set(pendingMessages)
        let shown = summaries.filter { !held.contains($0.id) }
        let previous = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        if hasInteracted, shown.contains(where: { previous[$0.id] == nil }) {
            for message in messages where expansionOverrides[message.id] == nil {
                expansionOverrides[message.id] = message.isExpanded
            }
        }
        for summary in shown where expansionOverrides[summary.id] == nil {
            if let old = previous[summary.id], old.summary.isUnread, !summary.isUnread {
                expansionOverrides[summary.id] = old.isExpanded
            }
        }
        let lastKey = shown.last?.id
        messages = shown.map { summary in
            let expanded = expansionOverrides[summary.id] ?? (summary.isUnread || summary.id == lastKey)
            let old = previous[summary.id]
            return Message(summary: summary, isExpanded: expanded, body: old?.body ?? .notLoaded,
                           imagesShown: old?.imagesShown, colorOverride: old?.colorOverride,
                           quotesExpanded: quoteState.contains(summary.id), accessory: old?.accessory)
        }
        if !messages.contains(where: { $0.id == focusedMessage }) { focusChosen = false }
        if !focusChosen { focusedMessage = messages.last?.id }
        refreshDerived(bump: false)
        let wanted = Set(messages.filter(\.isExpanded).map(\.id))
        for (key, task) in bodyTasks where !wanted.contains(key) {
            task.cancel()
            bodyTasks[key] = nil
        }
        for key in messages.map(\.id) where wanted.contains(key) {
            observeBody(key)
            loadAccessory(key)
        }
        state = .loaded
        revision += 1
    }

    private func observeSettings() {
        for task in settingsTasks { task.cancel() }
        settingsTasks = []
        guard let settings else {
            settingsReady = true
            return
        }
        settingsSeen = []
        settingsReady = false
        let account = thread.account
        settingsTasks.append(observe(0, settings.observe(AppSettings.remoteImages(account))) { $0.imagePolicy = $1 })
        settingsTasks.append(observe(1, settings.observe(AppSettings.remoteImageSenders(account))) { $0.allowedSenders = $1 })
        settingsTasks.append(observe(2, settings.observe(ReaderSettings.colorOverrides(account))) { $0.colorOverrides = $1 })
    }

    private func observe<V: Sendable & Equatable>(_ index: Int, _ stream: AsyncStream<V>,
                                                  _ apply: @escaping @MainActor (ReaderModel, V) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            for await value in stream {
                guard !Task.isCancelled, let self else { return }
                apply(self, value)
                self.settingSeen(index)
            }
            guard !Task.isCancelled else { return }
            self?.settingSeen(index)
        }
    }

    private func settingSeen(_ index: Int) {
        settingsSeen.insert(index)
        if settingsSeen.count == 3 { settingsReady = true }
        settingsChanged()
    }

    private func settingsChanged() {
        refreshDerived()
        for message in messages where message.isExpanded { render(message.id) }
    }

    private func refreshDerived(bump: Bool = true) {
        var changed = false
        for i in messages.indices {
            let key = messages[i].id
            let shown = imageDecision(key).1
            let color = RemoteContentPolicy.colorOverride(forSender: messages[i].summary.from?.email, in: colorOverrides)
            if messages[i].imagesShown != shown { messages[i].imagesShown = shown; changed = true }
            if messages[i].colorOverride != color { messages[i].colorOverride = color; changed = true }
        }
        if changed, bump { revision += 1 }
    }

    private func observeBody(_ key: MessageKey) {
        guard bodyTasks[key] == nil else {
            render(key)
            return
        }
        let stream = data.body(key)
        bodyTasks[key] = Task { [weak self] in
            do {
                for try await load in stream {
                    guard !Task.isCancelled, let self else { return }
                    switch load {
                    case .fetching:
                        if self.contents[key] == nil { self.setBody(key, .fetching) }
                    case .failed(let reason):
                        self.setBody(key, .failed(reason))
                    case .available(let content):
                        self.contents[key] = content
                        self.render(key)
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.setBody(key, .failed(String(describing: error)))
            }
        }
    }

    public func renderContext(_ key: MessageKey) -> RenderContext {
        let sender = message(key)?.summary.from?.email
        return RenderContext(allowRemoteImages: imageDecision(key).0 == .load,
                             colorOverride: RemoteContentPolicy.colorOverride(forSender: sender, in: colorOverrides),
                             textFormat: Self.plainTextFormat(contents[key]?.textFormat ?? .fixed),
                             keepOriginalSpacing: originalSpacing.contains(key))
    }

    nonisolated static func plainTextFormat(_ format: MessageTextFormat) -> PlainTextFormat {
        switch format {
        case .fixed: .fixed
        case .flowed(let delSp): .flowed(delSp: delSp)
        }
    }

    private func render(_ key: MessageKey) {
        guard settingsReady, let content = contents[key], let message = message(key), message.isExpanded else { return }
        let context = renderContext(key)
        let renderer = renderQueue.renderer
        let cacheKey = renderer.cacheKey(for: key, context: context)
        if renderedWith[key] == cacheKey, case .rendered = message.body { return }
        renderTasks[key]?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        let queue = renderQueue
        renderTasks[key] = Task { [weak self] in
            let rendered = await queue.renderUnlessCancelled(content, for: key, context: context, renderer: renderer)
            guard !Task.isCancelled, let self, let rendered else { return }
            self.renderTasks[key] = nil
            self.renderedWith[key] = cacheKey
            self.setBody(key, .rendered(rendered))
        }
    }

    private func setBody(_ key: MessageKey, _ body: BodyState) {
        guard let i = messages.firstIndex(where: { $0.id == key }), messages[i].body != body else { return }
        messages[i].body = body
        revision += 1
    }
}
