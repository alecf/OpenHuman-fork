import Foundation
import MailModel
import Observation
import OpenHumanAI

@MainActor @Observable
public final class ThreadLineSummaries {
    public enum State: Equatable, Sendable {
        case generating
        case ready(String)
        case unavailable
    }

    public private(set) var states: [ThreadKey: State] = [:]
    public private(set) var isPausedForPower = false

    @ObservationIgnored public var backgroundLimit = 50
    @ObservationIgnored public var maxConcurrent = 1
    @ObservationIgnored public var backgroundDelay: Duration = .seconds(5)
    @ObservationIgnored public var isConstrained: @MainActor () -> Bool = {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var lines: [ThreadKey: (newest: MessageKey, text: String)] = [:]
    @ObservationIgnored private var queue: [ThreadKey] = []
    @ObservationIgnored private var foreground: Set<ThreadKey> = []
    @ObservationIgnored private var running: [ThreadKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

    init(center: AICenter) {
        self.center = center
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    isolated deinit {
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        backgroundTask?.cancel()
        for task in running.values { task.cancel() }
    }

    public func line(for thread: ThreadKey) -> String? {
        if case .ready(let text)? = states[thread] { return text }
        return nil
    }

    public func isGenerating(_ thread: ThreadKey) -> Bool { states[thread] == .generating }

    public func makeEnabledSetting() -> StoredSetting<Bool> {
        StoredSetting(AppSettings.aiSummarizeEveryConversation, port: center?.environment?.settings)
    }

    public func request(_ thread: ThreadKey) {
        foreground.insert(thread)
        queue.removeAll { $0 == thread }
        queue.insert(thread, at: 0)
        pump()
    }

    func prepare(_ thread: ThreadKey) async -> Bool {
        guard let center, await isEnabled(), running[thread] == nil, !Task.isCancelled else { return false }
        guard let context = await center.context(for: thread, trigger: .automatic),
              let newest = context.messageKeys.last, !Task.isCancelled else { return false }
        if let known = lines[thread], known.newest == newest {
            if states[thread] == nil { states[thread] = .ready(known.text) }
            return false
        }
        do {
            let line = try await center.features.summarizeLine(context.input)
            guard !Task.isCancelled else { return true }
            lines[thread] = (newest, line.text)
            states[thread] = .ready(line.text)
            return !line.fromCache
        } catch {
            return true
        }
    }

    public func leave(_ thread: ThreadKey) {
        guard foreground.remove(thread) != nil else { return }
        queue.removeAll { $0 == thread }
        if let task = running.removeValue(forKey: thread) {
            task.cancel()
            if states[thread] == .generating { states[thread] = nil }
            pump()
        }
    }

    public func precomputeInbox() async {
        await enqueueInbox(since: nil)
    }

    public func summarizeRecent(days: Int = 7, now: Date = Date()) async {
        await enqueueInbox(since: now.addingTimeInterval(-Double(days) * 86_400))
    }

    public func cancelBackground() {
        backgroundTask?.cancel()
        queue.removeAll { !foreground.contains($0) }
        for (thread, task) in running where !foreground.contains(thread) {
            task.cancel()
            running[thread] = nil
            if states[thread] == .generating { states[thread] = nil }
        }
    }

    public func reset() {
        cancelBackground()
        for task in running.values { task.cancel() }
        running = [:]
        queue = []
        foreground = []
        lines = [:]
        states = [:]
    }

    private func enqueueInbox(since: Date?) async {
        guard let center, let environment = center.environment, await isEnabled() else { return }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        for account in accounts {
            guard !Task.isCancelled else { return }
            guard let page = try? await environment.data.threadPage(.system(.inbox), account: account.id, after: nil,
                                                                    limit: backgroundLimit) else { continue }
            for row in page.rows where since.map({ row.lastMessageAt >= $0 }) ?? true {
                guard states[row.id] == nil, !queue.contains(row.id), running[row.id] == nil else { continue }
                queue.append(row.id)
            }
        }
        pump()
    }

    func pump() {
        isPausedForPower = false
        while running.count < maxConcurrent, let index = queue.firstIndex(where: { canStart($0) }) {
            let thread = queue.remove(at: index)
            running[thread] = Task { [weak self] in
                await self?.run(thread)
                guard let self else { return }
                self.running[thread] = nil
                self.pump()
            }
        }
        if queue.contains(where: { !foreground.contains($0) }), isConstrained() { isPausedForPower = true }
    }

    private func canStart(_ thread: ThreadKey) -> Bool {
        foreground.contains(thread) || !isConstrained()
    }

    private func run(_ thread: ThreadKey) async {
        guard let center, await isEnabled(), !Task.isCancelled else {
            if states[thread] == .generating { states[thread] = nil }
            return
        }
        guard let context = await center.context(for: thread, trigger: .automatic),
              let newest = context.messageKeys.last, !Task.isCancelled else {
            if !Task.isCancelled { states[thread] = .unavailable }
            return
        }
        if let known = lines[thread], known.newest == newest {
            states[thread] = .ready(known.text)
            return
        }
        states[thread] = .generating
        do {
            let line = try await center.features.summarizeLine(context.input)
            guard !Task.isCancelled else { return }
            lines[thread] = (newest, line.text)
            states[thread] = .ready(line.text)
        } catch {
            guard !Task.isCancelled else { return }
            states[thread] = .unavailable
        }
    }

    private func isEnabled() async -> Bool {
        guard let center, center.settings.enabled else { return false }
        guard let settings = center.environment?.settings,
              let stored = try? await settings.get(AppSettings.aiSummarizeEveryConversation) else {
            return AppSettings.aiSummarizeEveryConversation.defaultValue
        }
        return stored
    }
}
