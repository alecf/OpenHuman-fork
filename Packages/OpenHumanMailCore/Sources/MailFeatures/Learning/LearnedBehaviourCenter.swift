import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

extension AppSettings {
    public static let learnFromActions = AppSettingKey(name: "importance.learn_from_actions", defaultValue: false)
    public static let learnSeedFromSuperhumanLabels = AppSettingKey(name: "importance.learn_seed_superhuman",
                                                                    defaultValue: false)
}

public protocol LearnedBehaviourStoring: Sendable {
    func load() async -> LearnedBehaviour?
    func save(_ behaviour: LearnedBehaviour) async
    func clear() async
}

public actor InMemoryLearnedBehaviourStore: LearnedBehaviourStoring {
    private var stored: LearnedBehaviour?
    public init(_ initial: LearnedBehaviour? = nil) { stored = initial }
    public func load() async -> LearnedBehaviour? { stored }
    public func save(_ behaviour: LearnedBehaviour) async { stored = behaviour }
    public func clear() async { stored = nil }
}

@MainActor @Observable
public final class LearnedBehaviourCenter {
    public private(set) var isOn = false
    public private(set) var suggestions: [LearnedSuggestion] = []
    public private(set) var report = ClassifierAgreementReport(rows: [])
    public private(set) var observationCount = 0
    public private(set) var errorMessage: String?
    public private(set) var seedOn = false
    public private(set) var seedMessage: String?
    public private(set) var isSeeding = false

    public static let seedTitle = "Start from my Superhuman labels"
    public static let seedDetail = "Counts which conversations Superhuman categorised you archived or starred, so "
        + "suggestions need not wait for weeks of actions. Reads this Mac's copy only, changes nothing in Gmail, runs "
        + "once per account and only when you press Learn Now."

    public static let switchTitle = "Learn from what I do"
    public static let switchDetail = "Mail notices which senders you archive without reading, reply to quickly, star or "
        + "mute, and suggests changes. Only on this Mac. It never moves mail without asking."
    public static let resetTitle = "Reset learned behaviour"
    public nonisolated static let quickReply: TimeInterval = 3_600
    public nonisolated static let maxThreadsPerAction = 50

    @ObservationIgnored public var policy = LearnedSuggestionPolicy()
    @ObservationIgnored public private(set) var behaviour = LearnedBehaviour()
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let store: any LearnedBehaviourStoring
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var accountEmails: [AccountID: String] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingSwitch: Bool?
    @ObservationIgnored private var recording: [Task<Void, Never>] = []
    private static let observerKey = "learnedBehaviour"

    public init(environment: AppEnvironment, store: any LearnedBehaviourStoring,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.store = store
        self.now = now
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        environment?.actions.performedObservers[Self.observerKey] = nil
    }

    public func start() async {
        guard !loaded, let environment else { return }
        loaded = true
        behaviour = await store.load() ?? LearnedBehaviour()
        environment.actions.performedObservers[Self.observerKey] = { [weak self] id, context in
            self?.observe(id, context: context)
        }
        if let settings = environment.settings {
            isOn = (try? await settings.get(AppSettings.learnFromActions)) ?? false
            seedOn = (try? await settings.get(AppSettings.learnSeedFromSuperhumanLabels)) ?? false
            tasks.append(Task { [weak self] in
                for await on in settings.observe(AppSettings.learnFromActions) {
                    guard let self else { return }
                    if let pending = self.pendingSwitch {
                        guard on == pending else { continue }
                        self.pendingSwitch = nil
                    }
                    self.isOn = on
                    await self.refresh()
                }
            })
        }
        tasks.append(Task { [weak self] in
            let data = environment.data
            do {
                for try await list in data.accounts() {
                    guard let self else { return }
                    self.accountEmails = Dictionary(list.map { ($0.id, $0.email.lowercased()) },
                                                    uniquingKeysWith: { first, _ in first })
                }
            } catch {}
        })
        await refresh()
    }

    public func setOn(_ on: Bool) async {
        isOn = on
        if let settings = environment?.settings {
            pendingSwitch = on
            do {
                try await settings.set(AppSettings.learnFromActions, on)
            } catch {
                pendingSwitch = nil
            }
        }
        await refresh()
    }

    public func setSeedOn(_ on: Bool) async {
        let old = seedOn
        seedOn = on
        guard let settings = environment?.settings else { return }
        do {
            try await settings.set(AppSettings.learnSeedFromSuperhumanLabels, on)
        } catch {
            seedOn = old
        }
    }

    public func learnNow() async {
        guard !isSeeding else { return }
        isSeeding = true
        seedMessage = String(localized: "Reading this Mac's labels…")
        let result = await seedFromSuperhumanLabels()
        seedMessage = result.text
        isSeeding = false
    }

    func observe(_ id: ActionID, context: ActionContext) {
        guard isOn, let account = context.account, let kind = Self.signalKind(for: id, context: context) else { return }
        let threads = Array(context.selection.prefix(Self.maxThreadsPerAction))
        guard !threads.isEmpty else { return }
        let singleUnread = threads.count == 1 ? context.targets.anyUnread : nil
        recording.append(Task { [weak self] in
            await self?.record(kind, threads: threads, account: account, singleUnread: singleUnread)
        })
    }

    public func settle() async {
        while !recording.isEmpty {
            let pending = recording
            recording = []
            for task in pending { await task.value }
        }
    }

    enum SignalKind { case archive, star, mute, reply, other, important }

    static func signalKind(for id: ActionID, context: ActionContext) -> SignalKind? {
        switch id {
        case .markDone, .unsubscribeAndDone, .removeLabelAndDone: return .archive
        case .toggleStar: return context.targets.allStarred ? nil : .star
        case .toggleMute: return context.targets.allMuted ? nil : .mute
        case .reply, .replyAll: return .reply
        case .moveToOther, .neverImportant, .neverImportantDomain: return .other
        case .moveToImportant, .alwaysImportantSender, .alwaysImportantDomain: return .important
        default: return nil
        }
    }

    private func record(_ kind: SignalKind, threads: [ThreadKey], account: AccountID, singleUnread: Bool?) async {
        guard let environment else { return }
        let date = now()
        let own = accountEmails[account]
        let categories = environment.autoLabels?.index
        for key in threads {
            guard let detail = await AIThreadLoader.first(environment.data.threadDetail(key)) ?? nil else { continue }
            let others = detail.messages.filter { message in
                guard let from = message.from?.email.lowercased() else { return false }
                return from != own
            }
            let newest = others.max { $0.date < $1.date }
            let signal: TriageSignal
            switch kind {
            case .archive:
                let unread = singleUnread ?? detail.messages.contains(where: \.isUnread)
                signal = unread ? .archivedUnread : .archivedRead
            case .star: signal = .starred
            case .mute: signal = .muted
            case .reply:
                guard let newest else { continue }
                signal = date.timeIntervalSince(newest.date) <= Self.quickReply ? .repliedQuickly : .repliedLater
            case .other: signal = .movedToOther
            case .important: signal = .movedToImportant
            }
            if let sender = newest?.from?.email, !sender.isEmpty {
                behaviour.record(signal, for: LearnedSubject(account: account, kind: .sender, value: sender), at: date)
            }
            if let category = categories?.category(account: account, thread: key.gmailThreadID, labelIDs: []) {
                behaviour.record(signal, for: LearnedSubject(account: account, kind: .category, value: category), at: date)
            }
        }
        await store.save(behaviour)
        await refresh()
    }

    public func recordWrongAutoLabel(_ category: String, account: AccountID, sender: String?) {
        guard isOn else { return }
        behaviour.recordWrongAutoLabel(category, account: account, sender: sender?.lowercased())
        recording.append(Task { [weak self] in
            guard let self else { return }
            await self.store.save(self.behaviour)
            await self.refresh()
        })
    }

    public func rejectedAutoLabels(account: AccountID, sender: String) -> Set<String> {
        guard isOn else { return [] }
        return behaviour.rejectedAutoLabels(account: account, sender: sender.lowercased())
    }

    public func refresh() async {
        observationCount = behaviour.observationCount
        report = ClassifierAgreementReport.make(from: behaviour)
        guard isOn else {
            suggestions = []
            return
        }
        var covered: Set<LearnedSubject> = []
        if let port = environment?.importance {
            let accounts = Set(behaviour.tendencies.keys.map(\.account))
            for account in accounts {
                for rule in await AIThreadLoader.first(port.rules(account)) ?? [] where rule.effect == .neverImportant {
                    switch rule.kind {
                    case .neverSender:
                        covered.insert(LearnedSubject(account: account, kind: .sender, value: rule.value))
                    case .matcher:
                        if let category = AutoLabelRule.category(inValue: rule.value) {
                            covered.insert(LearnedSubject(account: account, kind: .category, value: category))
                        }
                    default: break
                    }
                }
            }
        }
        suggestions = behaviour.suggestions(at: now(), policy: policy, covered: covered)
    }

    @discardableResult
    public func accept(_ suggestion: LearnedSuggestion) async -> Bool {
        errorMessage = nil
        guard let environment, let port = environment.importance else {
            errorMessage = "Importance rules aren't available with this mail source."
            return false
        }
        let subject = suggestion.subject
        let change: ImportanceChange
        switch subject.kind {
        case .sender:
            change = ImportanceChange(kind: .neverSender, account: subject.account, value: subject.value)
        case .category:
            guard let value = AutoLabelRule.value(for: subject.value) else { return false }
            change = ImportanceChange(kind: .matcher, account: subject.account, value: value, effect: .neverImportant)
        }
        do {
            let title = "Moved \(subject.value) to Other"
            if let undo = environment.undo {
                try await undo.perform("\(title)", via: port) { try await port.apply(change) }
            } else {
                _ = try await port.apply(change)
            }
        } catch {
            errorMessage = (error as? MailPortError)?.description ?? "That change couldn't be saved."
            return false
        }
        behaviour.accepted.insert(subject)
        await store.save(behaviour)
        await refresh()
        return true
    }

    public func notNow(_ suggestion: LearnedSuggestion) async {
        behaviour.notNow[suggestion.subject] = now()
        await store.save(behaviour)
        await refresh()
    }

    public func reset() async {
        behaviour = LearnedBehaviour()
        await store.clear()
        await refresh()
    }

    public func bannerSuggestion(account: AccountID?) -> LearnedSuggestion? {
        guard isOn, let account else { return nil }
        return suggestions.first { $0.subject.account == account }
    }
}

public enum LearnSeedResult: Sendable, Hashable {
    case off(String)
    case alreadyDone
    case nothingFound
    case seeded(conversations: Int)

    public var text: String {
        switch self {
        case .off(let why): why
        case .alreadyDone: String(localized: "Already learned from this account's Superhuman labels.")
        case .nothingFound: String(localized: "No conversations under Superhuman's categories were found on this account.")
        case .seeded(let n):
            n == 1 ? String(localized: "Learned from 1 conversation Superhuman categorised.")
                   : String(localized: "Learned from \(n.formatted()) conversations Superhuman categorised.")
        }
    }
}

public enum LearnSeed {
    public static let maximumConversations = 2_000

    static func signals(for row: ThreadRow, inInbox: Bool) -> [TriageSignal] {
        var found: [TriageSignal] = []
        if !inInbox { found.append(row.isUnread ? .archivedUnread : .archivedRead) }
        if row.isStarred { found.append(.starred) }
        return found
    }

    struct Observation: Sendable, Hashable {
        let sender: String?
        let category: String
        let signal: TriageSignal
        let date: Date
    }

    static func observations(_ items: [SuperhumanLabelImportModel.ScanItem], inbox: Set<ThreadKey>) -> (observations: [Observation], conversations: Int) {
        var out: [Observation] = []
        var conversations = 0
        for item in items.sorted(by: { $0.row.lastMessageAt > $1.row.lastMessageAt }).prefix(maximumConversations) {
            let signals = signals(for: item.row, inInbox: inbox.contains(item.row.id))
            guard !signals.isEmpty else { continue }
            conversations += 1
            let sender = item.row.participants.first { !$0.isMe && !$0.email.isEmpty }?.email
            for signal in signals {
                out.append(Observation(sender: sender, category: item.category, signal: signal, date: item.row.lastMessageAt))
            }
        }
        return (out.sorted { $0.date < $1.date }, conversations)
    }
}

extension LearnedBehaviourCenter {
    @discardableResult
    public func seedFromSuperhumanLabels(account requested: AccountID? = nil) async -> LearnSeedResult {
        guard let environment else { return .off(String(localized: "Mail isn't ready.")) }
        let settings = environment.settings
        let seedOn = (try? await settings?.get(AppSettings.learnSeedFromSuperhumanLabels)) ?? false
        guard isOn, seedOn else {
            return .off(String(localized: "Turn on “Learn from what I do” and “Start from my Superhuman labels” first."))
        }
        let list = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let account = requested ?? environment.router.active?.account.id ?? list.first?.id
        guard let account else { return .off(String(localized: "Sign in first.")) }
        guard !behaviour.seededAccounts.contains(account) else { return .alreadyDone }
        let hide = (try? await settings?.get(AppSettings.hideSuperhumanLabels)) ?? AppSettings.hideSuperhumanLabels.defaultValue
        let mapping = (try? await settings?.get(AppSettings.superhumanLabelMapping)) ?? [:]
        let rules = SuperhumanLabelRules(hidesLabels: hide, mapping: mapping)
        guard let scan = try? await SuperhumanLabelImportModel.scan(account: account, data: environment.data, rules: rules,
                                                                  maxPerLabel: LearnSeed.maximumConversations),
              let inbox = try? await ArchiveSuggestionModel.rows(of: .system(.inbox), account: account,
                                                                 data: environment.data) else {
            return .off(String(localized: "Couldn't read this account's labels."))
        }
        guard inbox.count < ArchiveSuggestionModel.maxScanned else {
            return .off(String(localized: "The inbox is too large to tell archived mail from mail still in it."))
        }
        let (observations, conversations) = LearnSeed.observations(scan.items, inbox: Set(inbox.map(\.id)))
        guard conversations > 0 else { return .nothingFound }
        for item in observations {
            if let sender = item.sender {
                behaviour.record(item.signal, for: LearnedSubject(account: account, kind: .sender, value: sender), at: item.date)
            }
            behaviour.record(item.signal, for: LearnedSubject(account: account, kind: .category, value: item.category),
                             at: item.date)
        }
        behaviour.seededAccounts.insert(account)
        await store.save(behaviour)
        await refresh()
        return .seeded(conversations: conversations)
    }
}
