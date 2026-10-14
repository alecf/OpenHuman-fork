import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class AIPreparationQueue {
    public enum Kind: Int, CaseIterable, Comparable, Sendable {
        case replies, summaryLine, classification, followUp

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .replies: "replies"
            case .summaryLine: "summaryLine"
            case .classification: "classification"
            case .followUp: "followUp"
            }
        }
    }

    public struct Job: Hashable, Sendable {
        public let thread: ThreadKey
        public let kind: Kind
    }

    public static let preparedFeatures: Set<AIFeature> = [.replyOptions, .summarize, .classify, .followUp]

    static func feature(_ kind: Kind) -> AIFeature {
        switch kind {
        case .replies: .replyOptions
        case .summaryLine: .summarize
        case .classification: .classify
        case .followUp: .followUp
        }
    }

    public enum Pause: Equatable, Sendable {
        case lowPower, thermal, budget
    }

    enum Tier: Int, CaseIterable { case opened, newMail, inbox }

    private(set) var tiers: [Tier: [Job]] = [:]
    public private(set) var running: Set<Job> = []
    public private(set) var pause: Pause?
    public internal(set) var isStarted = false
    public internal(set) var onDeviceReady: Bool?

    @ObservationIgnored public var inboxLimit = 30
    @ObservationIgnored public var maxConcurrent = 1
    @ObservationIgnored public var maxAge: TimeInterval = 7 * 86_400
    @ObservationIgnored public var hourlyBudget = 60
    @ObservationIgnored public var startDelay: Duration = .seconds(5)
    @ObservationIgnored public var isLowPowerMode: @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    @ObservationIgnored public var thermalState: @MainActor () -> ProcessInfo.ThermalState = {
        ProcessInfo.processInfo.thermalState
    }
    @ObservationIgnored public var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    @ObservationIgnored var runs: [Date] = []
    @ObservationIgnored private(set) var prepared: Set<ThreadKey> = []
    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var tasks: [Job: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var budgetTask: Task<Void, Never>?
    @ObservationIgnored private var watchers: [AccountID: Task<Void, Never>] = [:]
    @ObservationIgnored private var seen: [ThreadKey: Date] = [:]
    @ObservationIgnored private var rows: [ThreadKey: ThreadRow] = [:]
    @ObservationIgnored private var seeded: Set<AccountID> = []
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(center: AICenter) {
        self.center = center
        let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pump() }
            })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        startTask?.cancel()
        budgetTask?.cancel()
        for task in tasks.values { task.cancel() }
        for task in watchers.values { task.cancel() }
    }

    public var pending: [Job] { Tier.allCases.flatMap { tiers[$0] ?? [] } }

    public var remaining: Int { Set(pending.map(\.thread)).union(running.map(\.thread)).count }

    public var statusLine: String? {
        guard pause == nil, !running.isEmpty else { return nil }
        return String(localized: "Preparing replies… \(remaining) left")
    }

    public var isEnabled: Bool {
        guard let settings = center?.settings else { return false }
        return settings.enabled && (settings.prepareInAdvance || settings.autoDraftReplies)
    }

    func prepares(_ kind: Kind) -> Bool {
        guard let settings = center?.settings else { return false }
        return settings.prepareInAdvance || (kind == .replies && settings.autoDraftReplies)
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let delay = startDelay
        let sleep = self.sleep
        startTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.fill()
        }
    }

    func fill() async {
        guard isStarted, isEnabled, let center, let environment = center.environment else {
            pump()
            return
        }
        let ready = await center.onDeviceStatus().available
        onDeviceReady = ready
        guard ready, isEnabled else {
            pump()
            return
        }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        for account in accounts where watchers[account.id] == nil {
            watch(account.id, data: environment.data)
        }
        pump()
    }

    public func bump(_ thread: ThreadKey) {
        guard isStarted, isEnabled else { return }
        remove(thread)
        let jobs = Kind.allCases.filter(prepares).map { Job(thread: thread, kind: $0) }.filter { !running.contains($0) }
        tiers[.opened, default: []].insert(contentsOf: jobs, at: 0)
        pump()
    }

    public func settingsChanged() {
        if isEnabled {
            guard isStarted else { return }
            Task { await fill() }
        } else {
            cancelAll()
        }
    }

    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = []
        tiers = [:]
        for task in watchers.values { task.cancel() }
        watchers = [:]
        seeded = []
        seen = [:]
        budgetTask?.cancel()
        budgetTask = nil
        pause = nil
        publishLine()
    }

    public func clearPrepared() async {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = []
        tiers = [:]
        guard let center else { return }
        let threads = prepared
        prepared = []
        for thread in threads {
            for model in center.allQuickReplies(in: thread) { model.reset() }
            await center.cache?.invalidate(threadKey: AIThreadLoader.threadKey(thread))
        }
        center.inlineReplies.reset()
        Self.log("prepare cleared threads=\(threads.count)")
        pump()
    }

    public func systemDidWake() {
        guard isStarted else { return }
        Task { await fill() }
    }

    private func watch(_ account: AccountID, data: any MailDataSource) {
        let limit = inboxLimit
        watchers[account] = Task(priority: .utility) { [weak self] in
            do {
                for try await window in data.threadWindow(.system(.inbox), account: account, limit: limit) {
                    guard !Task.isCancelled else { return }
                    self?.inboxChanged(window.rows, account: account)
                }
            } catch {}
        }
    }

    func inboxChanged(_ list: [ThreadRow], account: AccountID) {
        guard isEnabled else { return }
        let cutoff = now().addingTimeInterval(-maxAge)
        var newest: [ThreadKey] = []
        var fresh: [ThreadKey] = []
        let first = !seeded.contains(account)
        for row in list.prefix(inboxLimit) where row.lastMessageAt >= cutoff {
            rows[row.id] = row
            if let known = seen[row.id] {
                if row.lastMessageAt > known { fresh.append(row.id) }
            } else if first {
                newest.append(row.id)
            } else {
                fresh.append(row.id)
            }
            seen[row.id] = row.lastMessageAt
        }
        seeded.insert(account)
        for thread in fresh {
            remove(thread)
            tiers[.newMail, default: []].append(contentsOf: Kind.allCases.filter(prepares).map { Job(thread: thread, kind: $0) })
        }
        let queued = Set(pending)
        for kind in Kind.allCases where prepares(kind) {
            for thread in newest {
                let job = Job(thread: thread, kind: kind)
                guard !queued.contains(job), !running.contains(job) else { continue }
                tiers[.inbox, default: []].append(job)
            }
        }
        if !fresh.isEmpty || !newest.isEmpty {
            Self.log("prepare queued newMail=\(fresh.count) inbox=\(newest.count)")
        }
        pump()
    }

    private func remove(_ thread: ThreadKey) {
        for tier in Tier.allCases { tiers[tier]?.removeAll { $0.thread == thread } }
    }

    func pump() {
        defer { publishLine() }
        guard isStarted, isEnabled, onDeviceReady == true else {
            pause = nil
            return
        }
        let thermal = thermalState()
        if isLowPowerMode() {
            pause = .lowPower
        } else if thermal == .serious || thermal == .critical {
            pause = .thermal
        } else if budgetSpent {
            pause = .budget
            waitForBudget()
        } else {
            pause = nil
        }
        guard pause == nil else { return }
        let room = max(1, min(2, maxConcurrent))
        while running.count < room, let job = takeNext() {
            running.insert(job)
            tasks[job] = Task(priority: .background) { [weak self] in
                let ranModel = await self?.run(job) ?? false
                self?.finished(job, ranModel: ranModel)
            }
        }
    }

    private func takeNext() -> Job? {
        for tier in Tier.allCases {
            guard var jobs = tiers[tier], !jobs.isEmpty else { continue }
            let job = jobs.removeFirst()
            tiers[tier] = jobs
            return job
        }
        return nil
    }

    private func finished(_ job: Job, ranModel: Bool) {
        guard running.remove(job) != nil else { return }
        tasks[job] = nil
        if ranModel { runs.append(now()) }
        pump()
    }

    var budgetSpent: Bool {
        let hourAgo = now().addingTimeInterval(-3_600)
        runs.removeAll { $0 < hourAgo }
        return runs.count >= hourlyBudget
    }

    private func waitForBudget() {
        guard budgetTask == nil, let oldest = runs.first else { return }
        let wait = max(1, oldest.addingTimeInterval(3_600).timeIntervalSince(now()))
        let sleep = self.sleep
        budgetTask = Task { [weak self] in
            do { try await sleep(.seconds(wait)) } catch { return }
            self?.budgetTask = nil
            self?.pump()
        }
    }

    private func publishLine() {
        center?.environment?.status.preparingLine = statusLine
    }

    func run(_ job: Job) async -> Bool {
        guard let center, isEnabled, prepares(job.kind), !Task.isCancelled else { return false }
        guard let context = await center.context(for: job.thread, trigger: .automatic),
              let newest = context.messageKeys.last, !Task.isCancelled else { return false }
        if let date = context.input.messages.last?.date, now().timeIntervalSince(date) > maxAge { return false }
        let ran: Bool
        switch job.kind {
        case .replies: ran = await prepareReplies(job.thread, context: context, newest: newest, center: center)
        case .summaryLine: ran = await center.threadLines.prepare(job.thread)
        case .classification: ran = await classify(job.thread, context: context, newest: newest, center: center)
        case .followUp: ran = await checkFollowUp(job.thread, context: context, newest: newest, center: center)
        }
        Self.log("prepare job=\(job.kind.name) ranModel=\(ran)")
        return ran
    }

    private func prepareReplies(_ thread: ThreadKey, context: AIThreadContext, newest: MessageKey,
                                center: AICenter) async -> Bool {
        guard center.showsInlineReplies, !center.settings.agentCLIAutoQuickReplies else { return false }
        let skip = NeedsReply.skipReason(center.needsReplyFacts(for: thread, context: context, row: rows[thread]))
        center.inlineReplies.record(skip.map { .skipped($0) } ?? .needsReply, thread: thread, message: newest)
        guard skip == nil else { return false }
        let model = center.quickReplies(for: thread, replyingTo: newest)
        guard model.phase == .idle else {
            await model.settled()
            return false
        }
        model.request(trigger: .automatic)
        guard model.phase == .loading else { return false }
        await model.settled()
        if model.phase == .ready { prepared.insert(thread) }
        return !model.fromCache
    }

    private func classify(_ thread: ThreadKey, context: AIThreadContext, newest: MessageKey,
                          center: AICenter) async -> Bool {
        guard center.settings.backgroundTriage, center.classification(of: thread, newest: newest) == nil else {
            return false
        }
        guard let result = try? await center.features.classify(context.input), !Task.isCancelled else { return true }
        center.remember(result.category, of: thread, newest: newest)
        return true
    }

    private func checkFollowUp(_ thread: ThreadKey, context: AIThreadContext, newest: MessageKey,
                               center: AICenter) async -> Bool {
        guard context.lastIsFromMe, let environment = center.environment,
              let account = center.account(thread.account) else { return false }
        let rule = await SentMailReminderRule.load(from: environment.settings)
        guard rule.scope == .needsFollowUp,
              let detail = await AIThreadLoader.first(environment.data.threadDetail(thread)) ?? nil,
              let message = detail.messages.last, message.id == newest else { return false }
        let recipients = (message.to + message.cc + message.bcc).map(\.email)
        guard SentMailReminderRule.mayNeedFollowUp(recipients, myAddresses: account.myAddresses) else { return false }
        let input = FollowUpReminders.input(for: message, thread: thread, subject: detail.subject, account: account,
                                            accountKey: center.policyKey(thread.account), loaded: context.input.messages)
        _ = try? await center.features.detectFollowUp(input)
        return true
    }

    private nonisolated static let logger = Log(.ai)

    nonisolated static func log(_ line: String) {
        logger.info(line)
    }
}
