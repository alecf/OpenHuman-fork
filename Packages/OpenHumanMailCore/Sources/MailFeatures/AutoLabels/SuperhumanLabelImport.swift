import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class SuperhumanLabelImportModel {
    public struct Options: Sendable {
        public var writesToGmail: Bool?
        public var batchSize: Int
        public var maxPerLabel: Int
        public var previewCount: Int

        public init(writesToGmail: Bool? = nil, batchSize: Int = 500, maxPerLabel: Int = 10_000, previewCount: Int = 10) {
            self.writesToGmail = writesToGmail
            self.batchSize = max(1, batchSize)
            self.maxPerLabel = maxPerLabel
            self.previewCount = previewCount
        }
    }

    public struct CategoryCount: Identifiable, Hashable, Sendable {
        public let category: String
        public let sources: [String]
        public let total: Int
        public let toImport: Int
        public let alreadyOurs: Int
        public var id: String { category }
    }

    public struct Example: Identifiable, Hashable, Sendable {
        public let thread: ThreadKey
        public let subject: String
        public let lastMessageAt: Date
        public let superhumanName: String
        public let category: String
        public var id: ThreadKey { thread }
    }

    public struct UnconfirmedLabel: Identifiable, Hashable, Sendable {
        public let name: String
        public let conversations: Int
        public let isKnown: Bool
        public let mappedTo: String?
        public var id: String { name }
    }

    public enum Phase: Hashable, Sendable {
        case idle, counting, counted, importing, removing
        case done(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var account: Account?
    public private(set) var counts: [CategoryCount] = []
    public private(set) var preview: [Example] = []
    public private(set) var unconfirmed: [UnconfirmedLabel] = []
    public private(set) var plan: SuperhumanLabelPlan?
    public private(set) var removable = 0
    @ObservationIgnored public var options: Options
    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var removalPlan: [GmailLabelID: [ThreadKey]] = [:]

    public init(environment: AppEnvironment, options: Options = Options()) {
        self.environment = environment
        self.options = options
    }

    public static let note = String(localized: """
        Copies Superhuman's categories ([Superhuman]/AI/…) onto Mail's own hidden OpenHuman labels, once. Counts first \
        and changes nothing until you choose. Superhuman's labels stay as they are, so Superhuman keeps working. \
        Conversations Mail already sorted keep Mail's label.
        """)
    public static let hideNote = String(localized: """
        Leaves every [Superhuman] label out of chips, the label list and the label pickers in Mail. Only changes what Mail \
        shows; nothing in Gmail changes. A conversation Superhuman sorted that isn't imported yet shows its category in grey.
        """)
    public static let mappingNote = String(localized: """
        Superhuman labels whose meaning isn't documented are skipped unless you choose a Mail label for them here.
        """)
    public static let removeWarning = String(localized: """
        This takes Superhuman's own category labels off these conversations in Gmail. Superhuman will lose them: its \
        splits and views that use them will stop showing these conversations. Mail's labels stay. Undo (⌘Z) puts them \
        back. Superhuman's Muted and Is Snoozed labels are not touched.
        """)

    public var importTitle: String {
        let n = plan?.total ?? 0
        return n == 1 ? String(localized: "Import 1 conversation")
            : String(localized: "Import \(n.formatted()) conversations")
    }

    public var removeTitle: String {
        removable == 1 ? String(localized: "Remove Superhuman labels from 1 conversation…")
            : String(localized: "Remove Superhuman labels from \(removable.formatted()) conversations…")
    }

    public var writeBlockedReason: String? {
        guard let environment else { return String(localized: "Mail isn't ready.") }
        guard environment.commands != nil else { return String(localized: "This copy of Mail can't change labels.") }
        if let forced = options.writesToGmail { return forced ? nil : String(localized: "Mail may not change labels here.") }
        if environment.isFake {
            return String(localized: "Sample data: nothing is written. Superhuman's categories show in grey.")
        }
        if !environment.isLiveAccount {
            return String(localized: "Mail can't change labels in this session. Superhuman's categories show in grey.")
        }
        return nil
    }

    public var isBusy: Bool {
        switch phase {
        case .counting, .importing, .removing: true
        default: false
        }
    }

    public var canImport: Bool { !isBusy && (plan?.total ?? 0) > 0 && writeBlockedReason == nil }
    public var canRemove: Bool { !isBusy && removable > 0 && writeBlockedReason == nil }

    public func count(account requested: AccountID? = nil) async {
        guard environment != nil, !isBusy else { return }
        phase = .counting
        guard let account = await resolveAccount(requested) else {
            phase = .failed(String(localized: "Sign in first."))
            return
        }
        self.account = account
        do {
            try await recount(account)
            phase = .counted
        } catch {
            phase = .failed(String(localized: "Couldn't read this account's labels."))
        }
    }

    public func setMapping(_ category: String?, for name: String) async {
        guard let settings = environment?.settings else { return }
        var mapping = (try? await settings.get(AppSettings.superhumanLabelMapping)) ?? [:]
        for key in mapping.keys where key.caseInsensitiveCompare(name) == .orderedSame { mapping[key] = nil }
        if let category = category.flatMap(OHGmailLabels.canonicalAutoLabelCategory) { mapping[name] = category }
        do {
            try await settings.set(AppSettings.superhumanLabelMapping, mapping)
        } catch {
            phase = .failed(String(localized: "The choice for \(name) couldn't be saved."))
            return
        }
        if let account { await count(account: account.id) }
    }

    private func resolveAccount(_ requested: AccountID?) async -> Account? {
        guard let environment else { return nil }
        let list = await AIThreadLoader.first(environment.data.accounts()) ?? []
        if let requested { return list.first { $0.id == requested } }
        if let active = environment.router.active?.account { return active }
        return list.first
    }

    private func rules() async -> SuperhumanLabelRules {
        let settings = environment?.settings
        let hide = (try? await settings?.get(AppSettings.hideSuperhumanLabels)) ?? AppSettings.hideSuperhumanLabels.defaultValue
        let mapping = (try? await settings?.get(AppSettings.superhumanLabelMapping)) ?? [:]
        return SuperhumanLabelRules(hidesLabels: hide, mapping: mapping)
    }

    private func recount(_ account: Account) async throws {
        guard let environment else { return }
        let rules = await rules()
        let scan = try await Self.scan(account: account.id, data: environment.data, rules: rules,
                                       maxPerLabel: options.maxPerLabel)
        let own = await environment.autoLabels?.cachedOwnAnswers(account: account.id) ?? [:]
        let result = Self.plan(scan: scan, ownAnswers: Set(own.keys), rules: rules, previewCount: options.previewCount)
        counts = result.counts
        preview = result.preview
        plan = result.plan
        unconfirmed = result.unconfirmed
        removalPlan = result.removal
        removable = Set(result.removal.values.flatMap { $0 }).count
    }

    @discardableResult
    public func importLabels() async -> Bool {
        guard let environment, let account, !isBusy else { return false }
        if let reason = writeBlockedReason {
            phase = .failed(reason)
            return false
        }
        guard let commands = environment.commands else { return false }
        phase = .importing
        do {
            try await recount(account)
        } catch {
            phase = .failed(String(localized: "Couldn't read this account's labels."))
            return false
        }
        guard let plan, plan.total > 0 else {
            phase = .done(String(localized: "Nothing left to import."))
            return false
        }
        let run = PlanRun()
        do {
            if let undo = environment.undo {
                try await undo.perform("Imported Superhuman labels", threads: plan.threads,
                                       via: UndoSequence(port: commands)) {
                    try await self.apply(plan, commands: commands, run: run)
                }
            } else {
                _ = try await apply(plan, commands: commands, run: run)
            }
        } catch {
            phase = .failed(String(localized: "Couldn't import. Nothing was changed; try again."))
            return false
        }
        try? await recount(account)
        if run.stopped {
            phase = .done(String(localized: """
                Imported \(run.done.formatted()) of \(plan.total.formatted()) conversations, then stopped. Import again \
                to finish: it skips what's done.
                """))
        } else {
            phase = .done(run.done == 1 ? String(localized: "Imported 1 conversation. ⌘Z in the mail window takes it back.")
                : String(localized: "Imported \(run.done.formatted()) conversations. ⌘Z in the mail window takes them back."))
        }
        return run.done > 0
    }

    private final class PlanRun {
        var tokens: [UndoToken] = []
        var done = 0
        var stopped = false
    }

    private func apply(_ plan: SuperhumanLabelPlan, commands: any MailCommanding, run: PlanRun) async throws -> UndoToken {
        do {
            for step in plan.steps {
                var labelID = step.labelID
                for batch in Self.batches(step.threads, size: options.batchSize) {
                    try Task.checkCancellation()
                    if let id = labelID {
                        run.tokens.append(try await commands.apply(.modifyLabels(batch, add: [id], remove: [])))
                    } else if let name = OHGmailLabels.autoLabel(step.category) {
                        run.tokens.append(try await commands.createLabel(plan.account, name: name, applyTo: batch))
                        labelID = await ourLabelID(step.category, account: plan.account)
                    }
                    run.done += batch.count
                }
            }
        } catch {
            guard !run.tokens.isEmpty else { throw error }
            run.stopped = true
        }
        return try UndoSequence.token(run.tokens)
    }

    private func ourLabelID(_ category: String, account: AccountID) async -> GmailLabelID? {
        guard let data = environment?.data,
              let labels = await AIThreadLoader.first(data.labels(account)) else { return nil }
        return labels.first { OHGmailLabels.autoLabelCategory(inLabelName: $0.name) == category && $0.kind == .user }?.labelID
    }

    @discardableResult
    public func removeSuperhumanLabels() async -> Bool {
        guard let environment, let account, !isBusy else { return false }
        if let reason = writeBlockedReason {
            phase = .failed(reason)
            return false
        }
        guard let commands = environment.commands else { return false }
        phase = .removing
        do {
            try await recount(account)
        } catch {
            phase = .failed(String(localized: "Couldn't read this account's labels."))
            return false
        }
        let targets = removalPlan.sorted { $0.key.rawValue < $1.key.rawValue }.filter { !$0.value.isEmpty }
        guard !targets.isEmpty else {
            phase = .done(String(localized: "No Superhuman labels to remove."))
            return false
        }
        let threads = Array(Set(targets.flatMap(\.value))).sorted { $0.gmailThreadID.rawValue < $1.gmailThreadID.rawValue }
        let size = options.batchSize
        let work: () async throws -> UndoToken = {
            var tokens: [UndoToken] = []
            do {
                for (label, keys) in targets {
                    for batch in Self.batches(keys, size: size) {
                        tokens.append(try await commands.apply(.modifyLabels(batch, add: [], remove: [label])))
                    }
                }
                return try UndoSequence.token(tokens)
            } catch {
                for token in tokens.reversed() { _ = try? await commands.undo(token) }
                throw error
            }
        }
        do {
            if let undo = environment.undo {
                try await undo.perform("Removed Superhuman labels", threads: threads, via: UndoSequence(port: commands), work)
            } else {
                _ = try await work()
            }
        } catch {
            phase = .failed(String(localized: "Couldn't remove Superhuman's labels. Nothing was changed."))
            return false
        }
        try? await recount(account)
        phase = .done(threads.count == 1
            ? String(localized: "Removed Superhuman's labels from 1 conversation. ⌘Z in the mail window puts them back.")
            : String(localized: "Removed Superhuman's labels from \(threads.count.formatted()) conversations. ⌘Z in the mail window puts them back."))
        return true
    }

    struct ScanItem: Sendable, Hashable {
        let row: ThreadRow
        let category: String
        let superhumanName: String
    }

    struct Scan: Sendable {
        var labels: [LabelInfo]
        var items: [ScanItem]
    }

    nonisolated static func scan(account: AccountID, data: any MailDataSource, rules: SuperhumanLabelRules,
                                 maxPerLabel: Int) async throws -> Scan {
        let labels = try await SuperhumanImportModel.labels(account: account, data: data)
        let names = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let mapped = labels.filter { $0.kind == .user && rules.category(forLabelName: $0.name) != nil }
            .sorted { $0.name < $1.name }
        var seen = Set<ThreadKey>()
        var items: [ScanItem] = []
        for label in mapped {
            var cursor: PageCursor?
            var read = 0
            repeat {
                try Task.checkCancellation()
                let page = try await data.threadPage(.label(label.labelID), account: account, after: cursor, limit: 500)
                read += page.rows.count
                for row in page.rows where seen.insert(row.id).inserted {
                    // Count the label being read even when the row hides it (a label hidden in Gmail)
                    let rowNames = row.userLabelIDs.compactMap { names[$0] } + [label.name]
                    guard let category = rules.category(inLabelNames: rowNames) else { continue }
                    let source = rowNames.first { rules.category(forLabelName: $0) == category }
                        .flatMap(SuperhumanLabels.aiName) ?? category
                    items.append(ScanItem(row: row, category: category, superhumanName: source))
                }
                cursor = page.next
            } while cursor != nil && read < maxPerLabel
        }
        items.sort { $0.row.lastMessageAt != $1.row.lastMessageAt ? $0.row.lastMessageAt > $1.row.lastMessageAt
            : $0.row.id.gmailThreadID.rawValue < $1.row.id.gmailThreadID.rawValue }
        return Scan(labels: labels, items: items)
    }

    struct PlanResult {
        var counts: [CategoryCount]
        var preview: [Example]
        var plan: SuperhumanLabelPlan?
        var unconfirmed: [UnconfirmedLabel]
        var removal: [GmailLabelID: [ThreadKey]]
    }

    static func plan(scan: Scan, ownAnswers: Set<GmailThreadID>, rules: SuperhumanLabelRules,
                     previewCount: Int) -> PlanResult {
        let byRowID = Dictionary(scan.labels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var total: [String: Int] = [:], already: [String: Int] = [:]
        var sources: [String: Set<String>] = [:]
        var targets: [String: [ThreadKey]] = [:]
        var preview: [Example] = []
        var removal: [GmailLabelID: [ThreadKey]] = [:]
        for item in scan.items {
            let category = item.category
            total[category, default: 0] += 1
            sources[category, default: []].insert(item.superhumanName)
            let rowLabels = item.row.userLabelIDs.compactMap { byRowID[$0] }
            let hasOurs = rowLabels.contains { OHGmailLabels.autoLabelCategory(inLabelName: $0.name) != nil }
            if hasOurs {
                for label in rowLabels where rules.category(forLabelName: label.name) != nil {
                    removal[label.labelID, default: []].append(item.row.id)
                }
            }
            if hasOurs || ownAnswers.contains(item.row.id.gmailThreadID) {
                already[category, default: 0] += 1
                continue
            }
            targets[category, default: []].append(item.row.id)
            if preview.count < previewCount {
                preview.append(Example(thread: item.row.id, subject: item.row.subject, lastMessageAt: item.row.lastMessageAt,
                                       superhumanName: item.superhumanName, category: category))
            }
        }
        let order = OHGmailLabels.autoLabelCategories
        let counts = order.compactMap { category -> CategoryCount? in
            guard let n = total[category], n > 0 else { return nil }
            return CategoryCount(category: category, sources: (sources[category] ?? []).sorted(), total: n,
                                 toImport: targets[category]?.count ?? 0, alreadyOurs: already[category] ?? 0)
        }
        let account = scan.items.first?.row.id.account
        let steps = order.compactMap { category -> SuperhumanLabelPlan.Step? in
            guard let keys = targets[category], !keys.isEmpty else { return nil }
            let existing = scan.labels.first { $0.kind == .user && OHGmailLabels.autoLabelCategory(inLabelName: $0.name) == category }
            return SuperhumanLabelPlan.Step(category: category, labelID: existing?.labelID, threads: keys)
        }
        let plan = account.map { SuperhumanLabelPlan(account: $0, steps: steps) }
        let unconfirmed = scan.labels.compactMap { label -> UnconfirmedLabel? in
            guard label.kind == .user, let name = SuperhumanLabels.aiName(label.name),
                  !SuperhumanLabels.isConfirmed(aiName: name) else { return nil }
            let known = SuperhumanLabels.unconfirmedNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            return UnconfirmedLabel(name: name, conversations: label.totalThreads, isKnown: known,
                                    mappedTo: rules.category(forAIName: name))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return PlanResult(counts: counts, preview: preview, plan: plan, unconfirmed: unconfirmed, removal: removal)
    }

    nonisolated static func batches(_ keys: [ThreadKey], size: Int) -> [[ThreadKey]] {
        stride(from: 0, to: keys.count, by: max(1, size)).map { Array(keys[$0..<min($0 + max(1, size), keys.count)]) }
    }
}

public struct SuperhumanLabelPlan: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public let category: String
        public let labelID: GmailLabelID?
        public let threads: [ThreadKey]

        public init(category: String, labelID: GmailLabelID?, threads: [ThreadKey]) {
            self.category = category
            self.labelID = labelID
            self.threads = threads
        }
    }

    public let account: AccountID
    public let steps: [Step]

    public init(account: AccountID, steps: [Step]) {
        self.account = account
        self.steps = steps
    }

    public var total: Int { steps.reduce(0) { $0 + $1.threads.count } }
    public var threads: [ThreadKey] { steps.flatMap(\.threads) }
    public var addedLabelNames: [String] { steps.compactMap { OHGmailLabels.autoLabel($0.category) } }
}
