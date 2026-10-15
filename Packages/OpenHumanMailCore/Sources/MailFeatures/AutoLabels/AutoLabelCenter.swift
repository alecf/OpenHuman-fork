import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

public struct AutoLabelIndex: Sendable, Hashable {
    public var isOn: Bool
    public var ourLabels: [AccountID: [GmailLabelID: String]]
    public var importedLabels: [AccountID: [GmailLabelID: String]]
    public var threads: [AccountID: [GmailThreadID: String]]

    public init(isOn: Bool, ourLabels: [AccountID: [GmailLabelID: String]] = [:],
                importedLabels: [AccountID: [GmailLabelID: String]] = [:],
                threads: [AccountID: [GmailThreadID: String]] = [:]) {
        self.isOn = isOn
        self.ourLabels = ourLabels
        self.importedLabels = importedLabels
        self.threads = threads
    }

    public static let off = AutoLabelIndex(isOn: false)

    public func category(account: AccountID, thread: GmailThreadID?, labelIDs: [GmailLabelID]) -> String? {
        guard isOn else { return nil }
        if let ours = Self.first(labelIDs, in: ourLabels[account]) { return ours }
        if let thread, let category = threads[account]?[thread] { return category }
        return Self.first(labelIDs, in: importedLabels[account])
    }

    static func first(_ ids: [GmailLabelID], in map: [GmailLabelID: String]?) -> String? {
        guard let map, !map.isEmpty else { return nil }
        let found = Set(ids.compactMap { map[$0] })
        return OHGmailLabels.autoLabelCategories.first { found.contains($0) }
    }
}

@MainActor
@Observable
public final class AutoLabelCenter {
    public enum Availability: Equatable, Sendable {
        case checking, available
        case unavailable(String)
    }

    public struct Options: Sendable {
        public var writesToGmail: Bool?
        public var promptVersion: Int
        public var now: @Sendable () -> Date
        public var windowLimit: Int
        public var backfillDays: Int
        public var backfillLimit: Int
        public var resetLimitPerLabel: Int

        public init(writesToGmail: Bool? = nil, promptVersion: Int = AutoLabelPrompt.version,
                    now: @escaping @Sendable () -> Date = { Date() }, windowLimit: Int = 300, backfillDays: Int = 14,
                    backfillLimit: Int = 2_000, resetLimitPerLabel: Int = 5_000) {
            self.writesToGmail = writesToGmail
            self.promptVersion = promptVersion
            self.now = now
            self.windowLimit = windowLimit
            self.backfillDays = backfillDays
            self.backfillLimit = backfillLimit
            self.resetLimitPerLabel = resetLimitPerLabel
        }
    }

    public private(set) var availability: Availability = .checking
    public private(set) var isOn = false
    public private(set) var revision = 0
    public private(set) var isWorking = false
    public private(set) var lastMessage: String?

    @ObservationIgnored public var onIndexChange: (@Sendable (AutoLabelIndex) -> Void)? {
        didSet { onIndexChange?(index) }
    }
    @ObservationIgnored public private(set) var index = AutoLabelIndex.off
    @ObservationIgnored public var options: Options
    @ObservationIgnored public private(set) var modelCalls = 0
    @ObservationIgnored public private(set) var cacheHits = 0
    @ObservationIgnored public private(set) var failures = 0
    @ObservationIgnored public private(set) var corrections = 0
    @ObservationIgnored public private(set) var writeTokens: [UndoToken] = []
    public nonisolated static let maxWriteAttempts = 3

    @ObservationIgnored let store: any AutoLabelStoring
    @ObservationIgnored private(set) weak var environment: AppEnvironment?
    @ObservationIgnored private var enabledSetting = true
    @ObservationIgnored private var applySetting = true
    @ObservationIgnored private var since: Date?
    @ObservationIgnored private var classifier: (any AIClassificationProvider)?
    @ObservationIgnored private(set) var accounts: [AccountID: Account] = [:]
    @ObservationIgnored private(set) var labels: [AccountID: [LabelInfo]] = [:]
    @ObservationIgnored private var categories: [AccountID: [GmailThreadID: String]] = [:]
    @ObservationIgnored private(set) var entries: [AccountID: [GmailThreadID: AutoLabelEntry]] = [:]
    @ObservationIgnored var inFlight: Set<ThreadKey> = []
    @ObservationIgnored var decidedAt: [ThreadKey: Date] = [:]
    @ObservationIgnored private var writeAttempts: [ThreadKey: Int] = [:]
    @ObservationIgnored private var deferredConfirm: Set<ThreadKey> = []
    @ObservationIgnored private var labelBacked: [AccountID: Set<GmailThreadID>] = [:]
    @ObservationIgnored private var queue: [ThreadRow] = []
    @ObservationIgnored private var forced: Set<ThreadKey> = []
    @ObservationIgnored var seen: [ThreadKey: Date] = [:]
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID = 0
    @ObservationIgnored private(set) var inboxRows: [AccountID: [ThreadRow]] = [:]
    @ObservationIgnored var keySalt: Data?
    @ObservationIgnored var exampleTasks: [Task<Void, Never>] = []
    @ObservationIgnored var lastCorrected: (key: ThreadKey, row: ThreadRow?)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var accountTasks: [AccountID: [Task<Void, Never>]] = [:]

    public init(environment: AppEnvironment, store: any AutoLabelStoring, options: Options = Options()) {
        self.environment = environment
        self.store = store
        self.options = options
    }

    isolated deinit {
        worker?.cancel()
        for task in tasks { task.cancel() }
        for list in accountTasks.values { for task in list { task.cancel() } }
    }

    public func start() {
        guard tasks.isEmpty, let environment else { return }
        let settings = environment.settings
        let data = environment.data
        environment.classification.onChange { [weak self] _ in self?.rulesChanged() }
        tasks.append(Task { [weak self] in
            await self?.refreshAvailability()
            guard let settings else {
                await self?.applySettings(enabled: true, apply: true)
                return
            }
            let since = (try? await settings.get(AppSettings.autoLabelsSince)) ?? 0
            self?.restoreSince(since)
            for await enabled in settings.observe(AppSettings.autoLabelsEnabled) {
                guard let self else { return }
                await self.applySettings(enabled: enabled, apply: self.applySetting)
            }
        })
        if let settings {
            tasks.append(Task { [weak self] in
                for await apply in settings.observe(AppSettings.autoLabelsApplyToGmail) {
                    guard let self else { return }
                    await self.applySettings(enabled: self.enabledSetting, apply: apply)
                }
            })
        }
        if let settings {
            tasks.append(Task {
                for await show in settings.observe(AppSettings.autoLabelsShowInGmail) {
                    AutoLabelVisibility.showInGmail = show
                }
            })
        }
        tasks.append(Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard let self else { return }
                    await self.accountsChanged(list)
                }
            } catch {}
        })
    }

    public func refreshAvailability() async {
        let (found, reason) = await Self.onDeviceClassifier(environment?.ai)
        classifier = found
        availability = found == nil ? .unavailable(reason) : .available
        updateOn()
    }

    static func onDeviceClassifier(_ ai: AICenter?) async -> ((any AIClassificationProvider)?, String) {
        guard let ai, let registry = ai.registry else {
            return (nil, String(localized: "Auto labels need Apple's on-device model, which isn't set up in this copy of Mail."))
        }
        guard ai.settings.enabled else {
            return (nil, String(localized: "AI is off in Settings › AI."))
        }
        var reason: String?
        for classifier in ClassifierSelection.ordered(registry.classifiers, preference: ai.settings.classifier) {
            switch await classifier.availability() {
            case .available: return (classifier, "")
            case .unavailable(let why):
                if reason == nil { reason = AIWording.reason(why, providerName: classifier.displayName) }
            }
        }
        return (nil, reason ?? String(localized: "Auto labels need Apple's on-device model, which isn't available on this Mac."))
    }

    func prepareOnce() async {
        guard tasks.isEmpty, let environment else { return }
        await refreshAvailability()
        if let settings = environment.settings {
            enabledSetting = (try? await settings.get(AppSettings.autoLabelsEnabled)) ?? true
            applySetting = (try? await settings.get(AppSettings.autoLabelsApplyToGmail)) ?? true
            restoreSince((try? await settings.get(AppSettings.autoLabelsSince)) ?? 0)
        }
        updateOn()
        let list = await AIThreadLoader.first(environment.data.accounts()) ?? []
        accounts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let stored = try? await store.accountIDs() {
            for id in stored where accounts[id] == nil { try? await store.removeAll(account: id) }
        }
        for account in accounts.keys {
            if let rows = try? await store.entries(account: account) { load(rows, account: account) }
            if let list = await AIThreadLoader.first(environment.data.labels(account)) {
                labelsChanged(list, account: account)
            }
        }
    }

    private func restoreSince(_ seconds: Double) {
        since = seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private func applySettings(enabled: Bool, apply: Bool) async {
        enabledSetting = enabled
        applySetting = apply
        updateOn()
        if isOn, since == nil { await setSince(options.now()) }
        if isOn {
            enqueueInScope()
            for rows in inboxRows.values { reconcile(rows) }
        }
    }

    private func setSince(_ date: Date) async {
        since = date
        try? await environment?.settings?.set(AppSettings.autoLabelsSince, date.timeIntervalSince1970)
    }

    private func updateOn() {
        let on = enabledSetting && classifier != nil
        if on != isOn {
            isOn = on
            publishIndex()
        }
    }

    public var writesToGmail: Bool { applySetting && canChangeGmail }

    var canChangeGmail: Bool {
        guard let environment, environment.commands != nil else { return false }
        if let forced = options.writesToGmail { return forced }
        return !environment.isFake && environment.isLiveAccount
    }

    private func accountsChanged(_ list: [Account]) async {
        let current = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = Set(accounts.keys).subtracting(current.keys)
        accounts = current
        for id in removed { await forget(id) }
        if let stored = try? await store.accountIDs() {
            for id in stored where current[id] == nil { await forget(id) }
        }
        for id in current.keys where accountTasks[id] == nil { follow(id) }
    }

    private func forget(_ account: AccountID) async {
        for task in accountTasks[account] ?? [] { task.cancel() }
        accountTasks[account] = nil
        labels[account] = nil
        categories[account] = nil
        entries[account] = nil
        labelBacked[account] = nil
        queue.removeAll { $0.id.account == account }
        try? await store.removeAll(account: account)
        publishIndex()
    }

    private func follow(_ account: AccountID) {
        guard let data = environment?.data else { return }
        let limit = options.windowLimit
        let store = self.store
        var list: [Task<Void, Never>] = []
        list.append(Task { [weak self] in
            if let rows = try? await store.entries(account: account) { self?.load(rows, account: account) }
            do {
                for try await labels in data.labels(account) { self?.labelsChanged(labels, account: account) }
            } catch {}
        })
        list.append(Task { [weak self] in
            do {
                for try await window in data.threadWindow(.system(.inbox), account: account, limit: limit) {
                    self?.inboxChanged(window.rows)
                }
            } catch {}
        })
        accountTasks[account] = list
    }

    private func load(_ rows: [AutoLabelEntry], account: AccountID) {
        for entry in rows { remember(entry) }
        publishIndex()
    }

    func remember(_ entry: AutoLabelEntry) {
        entries[entry.account, default: [:]][entry.thread] = entry
        categories[entry.account, default: [:]][entry.thread] = entry.category
        noteSource(entry)
    }

    private func noteSource(_ entry: AutoLabelEntry) {
        if entry.source == .gmailLabel {
            labelBacked[entry.account, default: []].insert(entry.thread)
        } else {
            labelBacked[entry.account]?.remove(entry.thread)
        }
    }

    private func labelsChanged(_ list: [LabelInfo], account: AccountID) {
        labels[account] = list.filter { $0.kind == .user }
        publishIndex()
    }

    private func inboxChanged(_ rows: [ThreadRow]) {
        guard let account = rows.first?.id.account else { return }
        inboxRows[account] = rows
        guard isOn else { return }
        enqueue(rows.filter(inScope))
        reconcile(rows)
    }

    func enqueueInScope() {
        for rows in inboxRows.values { enqueue(rows.filter(inScope)) }
    }

    func inScope(_ row: ThreadRow) -> Bool {
        guard let since else { return false }
        return row.lastMessageAt >= since
    }

    private func enqueue(_ rows: [ThreadRow], force: Bool = false) {
        var added = false
        for row in rows {
            guard force || seen[row.id] != row.lastMessageAt else { continue }
            seen[row.id] = row.lastMessageAt
            if force { forced.insert(row.id) }
            queue.removeAll { $0.id == row.id }
            queue.append(row)
            added = true
        }
        if added { _ = kick() }
    }

    func kick() -> Task<Void, Never> {
        if let worker { return worker }
        workerID += 1
        let id = workerID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drain(id)
        }
        worker = task
        return task
    }

    private func drain(_ id: Int) async {
        isWorking = true
        while !queue.isEmpty, !Task.isCancelled {
            let batch = Array(queue.prefix(20))
            queue.removeFirst(batch.count)
            await process(batch)
        }
        guard workerID == id else { return }
        isWorking = false
        worker = nil
    }

    struct Decision {
        var row: ThreadRow
        var entry: AutoLabelEntry
        var fresh: Bool
        var context: DecisionContext?
    }

    private func process(_ rows: [ThreadRow]) async {
        let keys = Set(rows.map(\.id))
        inFlight.formUnion(keys)
        await decideAndWrite(rows)
        finishWriting(keys)
    }

    func finishWriting(_ keys: Set<ThreadKey>) {
        inFlight.subtract(keys)
        let deferred = deferredConfirm.intersection(keys)
        deferredConfirm.subtract(deferred)
        guard !deferred.isEmpty else { return }
        reconcile(inboxRows.values.flatMap { $0 }.filter { deferred.contains($0.id) }, confirmOnly: true)
    }

    private func decideAndWrite(_ rows: [ThreadRow]) async {
        guard isOn, let classifier else { return }
        await environment?.classification.load()
        let modelID = classifier.id.rawValue + "|" + (await classifier.modelVersion() ?? "unversioned")
        var decisions: [Decision] = []
        for row in rows {
            guard !Task.isCancelled, isOn else { break }
            let force = forced.remove(row.id) != nil
            guard var decision = await decide(row, classifier: classifier, modelID: modelID) else { continue }
            decidedAt[row.id] = row.lastMessageAt
            if force { decision.fresh = true }
            decisions.append(decision)
        }
        let fresh = decisions.filter(\.fresh)
        guard !fresh.isEmpty else { return }
        try? await store.put(fresh.map(\.entry))
        for decision in fresh { remember(decision.entry) }
        publishIndex()
        await logDecisions(fresh)
        if writesToGmail { await writeLabels(fresh) }
    }

    func decide(_ row: ThreadRow, classifier: any AIClassificationProvider, modelID: String) async -> Decision? {
        let account = row.id.account
        guard let data = environment?.data,
              let detail = await AIThreadLoader.first(data.threadDetail(row.id)) ?? nil,
              let latest = detail.messages.last else { return nil }
        let latestID = latest.id.gmailMessageID
        var existing = entries[account]?[row.id.gmailThreadID]
        if existing == nil { existing = try? await store.entry(account: account, thread: row.id.gmailThreadID) }
        let rejected = existing?.rejected ?? []
        var context: DecisionContext?
        func made(_ category: String?, _ source: AutoLabelSource, _ model: String, output: String? = nil,
                  rule: String? = nil) -> Decision {
            let entry = AutoLabelEntry(account: account, thread: row.id.gmailThreadID, latestMessage: latestID,
                                       promptVersion: options.promptVersion, modelID: model, category: category,
                                       source: source, classifiedAt: options.now(), rejected: rejected,
                                       writtenToGmail: source == .gmailLabel, modelOutput: output, ruleID: rule,
                                       ruleSetVersion: context?.ruleSetVersion)
            if let existing, existing.latestMessage == latestID, existing.category == entry.category,
               existing.source == source, existing.promptVersion == entry.promptVersion, existing.modelID == model {
                return Decision(row: row, entry: existing, fresh: false)
            }
            context?.modelOutput = output
            return Decision(row: row, entry: entry, fresh: true, context: context)
        }
        if let existing, existing.source == .user, existing.latestMessage == latestID {
            return Decision(row: row, entry: existing, fresh: false)
        }
        let verdict = await rulesVerdict(row: row, detail: detail, latest: latest, rejected: rejected)
        context = verdict
        if case .decided(let category) = verdict.verdict.outcome {
            let waiting = verdict.verdict.decidingRuleID == DefaultRules.waiting
            return made(category?.title, .derived, waiting ? "derived" : verdict.config.rulesModelID,
                        rule: verdict.verdict.decidingRuleID)
        }
        let forbidden = verdict.verdict.forbidden
        if let existing, existing.source != .derived,
           existing.isCurrent(latest: latestID, promptVersion: options.promptVersion, modelID: modelID) {
            cacheHits += 1
            if existing.source == .model, let output = existing.modelOutput {
                let resolved = verdict.verdict.resolve(AutoLabelCategory(title: output))?.title
                if resolved != existing.category { return made(resolved, .model, existing.modelID, output: output) }
                return Decision(row: row, entry: existing, fresh: false)
            }
            if let cached = existing.category.flatMap(AutoLabelCategory.init(title:)), forbidden.contains(cached) {
                return made(nil, existing.source, existing.modelID)
            }
            return Decision(row: row, entry: existing, fresh: false)
        }
        if existing == nil, let label = labelCategory(row) {
            return made(label, .gmailLabel, "gmail-label")
        }
        let attempt = [row.id.gmailThreadID.rawValue, latestID.rawValue, modelID, String(options.promptVersion)]
            .joined(separator: "|")
        guard !failed.contains(attempt) else { return nil }
        do {
            modelCalls += 1
            let category = try await classifier.autoLabel(Self.input(row: row, detail: detail, latest: latest,
                                                                     account: accounts[account]))
            if let category, !AutoLabelCategory.modelCategories.contains(category) {
                throw AIError.invalidOutput("not an auto label")
            }
            return made(verdict.verdict.resolve(category)?.title, .model, modelID, output: category?.title ?? "none")
        } catch {
            failed.insert(attempt)
            failures += 1
            if case AIError.unavailable(let reason) = error { markUnavailable(AIWording.reason(reason)) }
            return nil
        }
    }

    private var myAddresses: Set<String> { Set(accounts.values.flatMap(\.myAddresses)) }

    func signals(for latest: MessageSummary) async -> AutoLabelConversation.Signals {
        let mine = myAddresses
        let recipients = (latest.to + latest.cc).map { $0.email.lowercased() }
        let sender = (latest.from?.email ?? "").lowercased()
        func domain(_ address: String) -> String? {
            let parts = address.split(separator: "@")
            return parts.count == 2 ? String(parts[1]) : nil
        }
        var listUnsubscribe = false
        if let data = environment?.data { listUnsubscribe = (try? await data.unsubscribeInfo(latest.id)) != nil }
        return AutoLabelConversation.Signals(
            hasListUnsubscribe: listUnsubscribe, automatedSender: !sender.isEmpty && NeedsReply.isNoReply(sender),
            recipientCount: recipients.count,
            userIsRecipient: recipients.isEmpty || recipients.contains(where: mine.contains),
            senderSharesUserDomain: domain(sender).map { Set(mine.compactMap(domain)).contains($0) } ?? false,
            senderAddress: sender)
    }

    func conversation(_ detail: ConversationDetail,
                      signals: AutoLabelConversation.Signals = .init()) -> AutoLabelConversation {
        let mine = myAddresses
        let messages = detail.messages.map { message in
            AutoLabelConversation.Message(fromUser: mine.contains((message.from?.email ?? "").lowercased()),
                                          text: message.snippet)
        }
        var identities = mine
        for account in accounts.values {
            for name in [account.displayName] + account.sendAs.map(\.name) {
                if let name = name?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty { identities.insert(name) }
            }
        }
        return AutoLabelConversation(subject: detail.subject, messages: messages, userIdentities: identities,
                                     signals: signals)
    }

    private func markUnavailable(_ reason: String) {
        classifier = nil
        availability = .unavailable(reason)
        queue.removeAll()
        updateOn()
    }

    // Snippet only, not the body: background sorting must never download a message
    static func input(row: ThreadRow, detail: ConversationDetail, latest: MessageSummary, account: Account?)
        -> ClassificationInput {
        let threadKey = AIThreadLoader.threadKey(row.id)
        let messageKey = AIThreadLoader.messageKey(latest.id)
        let sender = AIThreadLoader.sender(latest.from, account: account)
        return ClassificationInput(
            threadKey: threadKey, accountKey: nil,
            subject: UntrustedPart(kind: .subject, id: threadKey, text: String(detail.subject.prefix(AIPolicy.subjectCharacterCap))),
            sender: UntrustedPart(kind: .sender, id: messageKey, text: String(sender.prefix(AIPolicy.senderCharacterCap))),
            excerpt: UntrustedPart(kind: .emailBody, id: messageKey,
                                   text: String(latest.snippet.prefix(AIPolicy.classifyExcerptCharacters)), date: latest.date))
    }

    func ourLabels(_ account: AccountID) -> [String: LabelInfo] {
        var out: [String: LabelInfo] = [:]
        for label in labels[account] ?? [] {
            if let category = OHGmailLabels.autoLabelCategory(inLabelName: label.name), out[category] == nil {
                out[category] = label
            }
        }
        return out
    }

    func labelCategory(_ row: ThreadRow) -> String? {
        let names = row.userLabelIDs.compactMap { id in labels[row.id.account]?.first { $0.id == id }?.name }
        return Self.ourCategory(inLabelNames: names)
    }

    static func ourCategory(inLabelNames names: [String]) -> String? {
        let ours = Set(names.compactMap { OHGmailLabels.autoLabelCategory(inLabelName: $0) })
        return OHGmailLabels.autoLabelCategories.first { ours.contains($0) }
    }


    private func writeLabels(_ decisions: [Decision]) async {
        guard let commands = environment?.commands else { return }
        struct Group { var keys: [ThreadKey] = []; var remove: Set<GmailLabelID> = [] }
        var groups: [AccountID: [String: Group]] = [:]
        for decision in decisions where decision.entry.source != .gmailLabel {
            let account = decision.row.id.account
            let ours = ourLabels(account)
            let onRow = Set(decision.row.userLabelIDs)
            let present = ours.filter { onRow.contains($0.value.id) }
            let wanted = decision.entry.category
            let remove = present.filter { $0.key != wanted }.map(\.value.labelID)
            let needsAdd = wanted.map { present[$0] == nil } ?? false
            guard needsAdd || !remove.isEmpty else { continue }
            var group = groups[account]?[wanted ?? ""] ?? Group()
            group.keys.append(decision.row.id)
            group.remove.formUnion(remove)
            groups[account, default: [:]][wanted ?? ""] = group
        }
        for (account, byCategory) in groups {
            let ours = ourLabels(account)
            for (category, group) in byCategory.sorted(by: { $0.key < $1.key }) {
                let remove = Array(group.remove).sorted { $0.rawValue < $1.rawValue }
                do {
                    if category.isEmpty {
                        let token = try await commands.apply(.modifyLabels(group.keys, add: [], remove: remove))
                        writeTokens.append(token)
                    } else if let label = ours[category] {
                        let token = try await commands.apply(.modifyLabels(group.keys, add: [label.labelID], remove: remove))
                        writeTokens.append(token)
                    } else if let name = OHGmailLabels.autoLabel(category) {
                        let created = try await commands.createLabel(account, name: name, applyTo: group.keys)
                        writeTokens.append(created)
                        if let data = environment?.data, let list = await AIThreadLoader.first(data.labels(account)) {
                            labelsChanged(list, account: account)
                        }
                        if !remove.isEmpty {
                            let token = try await commands.apply(.modifyLabels(group.keys, add: [], remove: remove))
                            writeTokens.append(token)
                        }
                    }
                } catch {
                    failures += 1
                    noteWriteFailed(group.keys)
                    Log(.app).notice("auto labels: a label write for \(group.keys.count) conversation(s) failed (\(String(describing: type(of: error)))); kept on this Mac")
                }
            }
        }
    }

    private func reconcile(_ rows: [ThreadRow], confirmOnly: Bool = false) {
        guard writesToGmail, !rows.isEmpty else { return }
        let queued = Set(queue.map(\.id))
        var rewrite: [Decision] = []
        for row in rows where !row.hasPendingChanges && !queued.contains(row.id) {
            guard decidedAt[row.id] == row.lastMessageAt,
                  let entry = entries[row.id.account]?[row.id.gmailThreadID] else { continue }
            if inFlight.contains(row.id) {
                deferredConfirm.insert(row.id)
                continue
            }
            let onGmail = labelCategory(row)
            if onGmail == entry.category {
                writeAttempts[row.id] = nil
                if !entry.writtenToGmail { confirm(entry) }
            } else if confirmOnly {
                continue
            } else if entry.writtenToGmail || entry.source == .user {
                takeCorrection(entry, nowOnGmail: onGmail, sender: nil)
            } else if writeAttempts[row.id, default: 0] < Self.maxWriteAttempts {
                writeAttempts[row.id, default: 0] += 1
                rewrite.append(Decision(row: row, entry: entry, fresh: true))
            }
        }
        guard !rewrite.isEmpty else { return }
        let keys = Set(rewrite.map(\.row.id))
        inFlight.formUnion(keys)
        Task { [weak self] in
            await self?.writeLabels(rewrite)
            self?.finishWriting(keys)
        }
    }

    private func confirm(_ entry: AutoLabelEntry) {
        var written = entry
        written.writtenToGmail = true
        remember(written)
        noteApplied(written, state: .written)
        let store = self.store
        Task { try? await store.put([written]) }
    }

    func takeCorrection(_ entry: AutoLabelEntry, nowOnGmail: String?, sender: String?, written: Bool = true) {
        var rejected = entry.rejected.filter { $0 != nowOnGmail }
        let wrong = entry.category.flatMap { $0 == nowOnGmail ? nil : $0 }
        if let wrong { rejected.append(wrong) }
        let corrected = AutoLabelEntry(account: entry.account, thread: entry.thread, latestMessage: entry.latestMessage,
                                       promptVersion: entry.promptVersion, modelID: "user", category: nowOnGmail,
                                       source: .user, classifiedAt: options.now(), rejected: rejected,
                                       writtenToGmail: written)
        remember(corrected)
        publishIndex()
        corrections += 1
        recordCorrection(entry, expected: nowOnGmail, source: sender == nil ? "gmail_change" : "correction")
        let store = self.store
        Task { try? await store.put([corrected]) }
        guard let wrong else { return }
        let environment = self.environment
        if let sender {
            environment?.learning.recordWrongAutoLabel(wrong, account: entry.account, sender: sender)
        } else if let environment {
            let row = inboxRows[entry.account]?.first { $0.id.gmailThreadID == entry.thread }
            Task { @MainActor in
                var from: String?
                if let row, let detail = await AIThreadLoader.first(environment.data.threadDetail(row.id)) ?? nil {
                    from = detail.messages.last?.from?.email.lowercased()
                }
                environment.learning.recordWrongAutoLabel(wrong, account: entry.account, sender: from)
            }
        }
    }

    @discardableResult
    public func markWrong(_ thread: ThreadKey, row: ThreadRow?, labels: [Int64: LabelInfo]) async throws -> String? {
        let account = thread.account
        let existing = entries[account]?[thread.gmailThreadID]
        guard let wrong = row.flatMap({ title(for: $0, labels: labels) }) ?? existing?.category else { return nil }
        var latestID = existing?.latestMessage
        var sender: String?
        if let data = environment?.data, let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil,
           let latest = detail.messages.last {
            latestID = latest.id.gmailMessageID
            sender = latest.from?.email.lowercased()
        }
        guard let latestID else { return nil }
        let base = AutoLabelEntry(account: account, thread: thread.gmailThreadID, latestMessage: latestID,
                                  promptVersion: existing?.promptVersion ?? options.promptVersion,
                                  modelID: existing?.modelID ?? "user", category: wrong, source: .user,
                                  classifiedAt: options.now(), rejected: existing?.rejected ?? [])
        lastCorrected = (thread, row)
        takeCorrection(base, nowOnGmail: nil, sender: sender ?? "", written: false)
        if let row { decidedAt[thread] = row.lastMessageAt }
        guard writesToGmail, let environment, let commands = environment.commands,
              let label = ourLabels(account)[wrong], row?.userLabelIDs.contains(label.id) ?? true else { return wrong }
        inFlight.insert(thread)
        defer { finishWriting([thread]) }
        let remove = MailCommand.modifyLabels([thread], add: [], remove: [label.labelID])
        if let undo = environment.undo {
            try await undo.perform("Removed the \(wrong) label", threads: [thread], via: commands) {
                try await commands.apply(remove)
            }
        } else {
            _ = try await commands.apply(remove)
        }
        return wrong
    }

    public func title(for row: ThreadRow, labels: [Int64: LabelInfo]) -> String? {
        _ = revision
        guard isOn else { return nil }
        let names = row.userLabelIDs.compactMap { labels[$0]?.name }
        if let ours = Self.ourCategory(inLabelNames: names) { return ours }
        if writesToGmail { return nil }
        let account = row.id.account, thread = row.id.gmailThreadID
        guard labelBacked[account]?.contains(thread) != true else { return nil }
        return categories[account]?[thread]
    }

    public func category(of thread: ThreadKey) -> String? {
        index.category(account: thread.account, thread: thread.gmailThreadID, labelIDs: [])
    }

    func publishIndex() {
        var ours: [AccountID: [GmailLabelID: String]] = [:]
        var imported: [AccountID: [GmailLabelID: String]] = [:]
        for (account, list) in labels {
            for label in list {
                if let category = OHGmailLabels.autoLabelCategory(inLabelName: label.name) {
                    ours[account, default: [:]][label.labelID] = category
                } else if let category = OHGmailLabels.superhumanAutoLabelCategory(inLabelName: label.name) {
                    imported[account, default: [:]][label.labelID] = category
                }
            }
        }
        let next = AutoLabelIndex(isOn: isOn, ourLabels: ours, importedLabels: imported, threads: categories)
        revision += 1
        guard next != index else { return }
        index = next
        onIndexChange?(next)
    }

    enum OwnAnswer: Sendable, Hashable {
        case answer(String?)
        case failed
        case unavailable
    }

    func cachedOwnAnswers(account: AccountID) async -> [GmailThreadID: String?] {
        guard let entries = try? await store.entries(account: account) else { return [:] }
        var out: [GmailThreadID: String?] = [:]
        for entry in entries where entry.source != .gmailLabel { out[entry.thread] = entry.category }
        return out
    }

    func ownAnswer(for row: ThreadRow) async -> OwnAnswer {
        guard let data = environment?.data,
              let detail = await AIThreadLoader.first(data.threadDetail(row.id)) ?? nil,
              let latest = detail.messages.last else { return .failed }
        await environment?.classification.load()
        let verdict = await rulesVerdict(row: row, detail: detail, latest: latest, rejected: [], senderRejections: false).verdict
        if case .decided(let category) = verdict.outcome { return .answer(category?.title) }
        guard let classifier else { return .unavailable }
        do {
            modelCalls += 1
            let category = try await classifier.autoLabel(Self.input(row: row, detail: detail, latest: latest,
                                                                     account: accounts[row.id.account]))
            if let category, !AutoLabelCategory.modelCategories.contains(category) { return .failed }
            return .answer(verdict.resolve(category)?.title)
        } catch {
            failures += 1
            return .failed
        }
    }

    func prepareForReport() async {
        await prepareOnce()
    }

    @discardableResult
    public func classifyRecent() async -> Int {
        await prepareOnce()
        guard isOn, let data = environment?.data else {
            lastMessage = String(localized: "Auto labels are off.")
            return 0
        }
        let cutoff = options.now().addingTimeInterval(-Double(options.backfillDays) * 86_400)
        var rows: [ThreadRow] = []
        for account in accounts.keys.sorted() {
            var cursor: PageCursor?
            var taken = 0
            repeat {
                guard let page = try? await data.threadPage(.system(.inbox), account: account, after: cursor, limit: 500)
                else { break }
                let recent = page.rows.filter { $0.lastMessageAt >= cutoff }
                rows += recent.prefix(max(0, options.backfillLimit - taken))
                taken += recent.count
                cursor = page.next
                if recent.count < page.rows.count { break }
            } while cursor != nil && taken < options.backfillLimit
        }
        enqueue(rows, force: true)
        await kick().value
        lastMessage = rows.count == 1 ? String(localized: "Sorted 1 conversation from the last \(options.backfillDays) days.")
            : String(localized: "Sorted \(rows.count) conversations from the last \(options.backfillDays) days.")
        return rows.count
    }

    public func reset() async {
        await prepareOnce()
        worker?.cancel()
        worker = nil
        queue.removeAll()
        forced.removeAll()
        failed.removeAll()
        seen = [:]
        var removedCount = 0
        var stayed = false
        if canChangeGmail, let environment, let commands = environment.commands {
            var keysByAccount: [AccountID: [ThreadKey]] = [:]
            var idsByAccount: [AccountID: [GmailLabelID]] = [:]
            for account in accounts.keys.sorted() {
                let ours = ourLabels(account).values.map(\.labelID)
                guard !ours.isEmpty else { continue }
                idsByAccount[account] = ours
                var keys: [ThreadKey] = []
                for label in ours {
                    var cursor: PageCursor?
                    repeat {
                        guard let page = try? await environment.data.threadPage(.label(label), account: account, after: cursor,
                                                                                 limit: 500) else { break }
                        keys += page.rows.map(\.id)
                        cursor = page.next
                    } while cursor != nil && keys.count < options.resetLimitPerLabel * ours.count
                }
                var unique: [ThreadKey] = []
                var known = Set<ThreadKey>()
                for key in keys where known.insert(key).inserted { unique.append(key) }
                if !unique.isEmpty { keysByAccount[account] = unique }
            }
            if !keysByAccount.isEmpty {
                let targets = keysByAccount.sorted(by: { $0.key < $1.key })
                let labelIDs = idsByAccount
                let work: @Sendable () async throws -> UndoToken = {
                    var tokens: [UndoToken] = []
                    do {
                        for (account, keys) in targets {
                            let token = try await commands.apply(.modifyLabels(keys, add: [], remove: labelIDs[account] ?? []))
                            tokens.append(token)
                        }
                        return try UndoSequence.token(tokens)
                    } catch {
                        for token in tokens.reversed() { _ = try? await commands.undo(token) }
                        throw error
                    }
                }
                do {
                    if let undo = environment.undo {
                        try await undo.perform("Removed auto labels", threads: keysByAccount.values.flatMap { $0 },
                                               via: UndoSequence(port: commands), work)
                    } else {
                        _ = try await work()
                    }
                    removedCount = keysByAccount.values.reduce(0) { $0 + $1.count }
                } catch {
                    stayed = true
                }
            }
        } else if accounts.keys.contains(where: { !ourLabels($0).isEmpty }) {
            stayed = true
        }
        try? await store.removeAll()
        categories = [:]
        entries = [:]
        decidedAt = [:]
        writeAttempts = [:]
        labelBacked = [:]
        await setSince(options.now())
        publishIndex()
        if stayed {
            lastMessage = String(localized: "Auto labels were cleared on this Mac. The labels in Gmail stay until Mail may change your mailbox.")
        } else {
            lastMessage = removedCount == 1 ? String(localized: "Removed auto labels from 1 conversation.")
                : String(localized: "Removed auto labels from \(removedCount) conversations.")
        }
    }
}
