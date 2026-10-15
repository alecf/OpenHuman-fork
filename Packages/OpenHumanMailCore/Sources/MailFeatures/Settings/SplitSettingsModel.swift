import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SplitSettingsModel {
    public struct Draft: Hashable {
        public var id: SplitKey?
        public var name: String
        public var ruleText: String
        public var enabled: Bool
    }

    public private(set) var accounts: [Account] = []
    public var account: AccountID? {
        didSet { if account != oldValue { accountChanged() } }
    }
    public private(set) var splits: [SplitInfo] = []
    public private(set) var otherUnread: Int?
    public private(set) var otherTotal: Int?
    public private(set) var hiddenWhenEmpty: Set<String> = []
    public private(set) var alsoShownInInbox: Set<String> = []
    public private(set) var splitsLoaded = false
    private var legacyMigrationDone = false
    public private(set) var eventsChange: EventsChange?
    public private(set) var eventsNote: String?
    public var draft: Draft?
    public private(set) var preview: String?
    public private(set) var errorMessage: String?
    public let availability: SettingsAvailability

    public static let previewLimit = 500
    public static let tabOptionsNote = "Important and Other are always in your inbox and can't be turned off. The eye menu on a tab only hides it while it has no mail."
    public static let otherNote = "Everything not in a split"

    public static func ruleSummary(_ rule: String, limit: Int = 36) -> String {
        let words = rule.split(whereSeparator: \.isWhitespace)
        let whole = words.joined(separator: " ")
        guard whole.count > limit else { return whole }
        var out = ""
        for word in words {
            let next = out.isEmpty ? String(word) : out + " " + word
            if next.count > limit { break }
            out = next
        }
        if out.isEmpty { out = String(whole.prefix(limit)) }
        return out + "…"
    }

    public static func unreadTitle(_ count: Int) -> String { "\(count) unread" }

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let commands: (any MailCommanding)?
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var countsTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var latestCounts: MailboxCountsInfo?
    @ObservationIgnored private var latestLabels: [LabelInfo] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var splitsTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    public init(data: any MailDataSource, commands: (any MailCommanding)?, settings: (any SettingsPort)? = nil,
                availability: SettingsAvailability) {
        self.data = data
        self.commands = commands
        self.settings = settings
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, commands: environment.commands, settings: environment.settings,
                  availability: SettingsAvailability(environment: environment))
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        splitsTask?.cancel()
        previewTask?.cancel()
        for task in countsTasks { task.cancel() }
    }

    public var canEdit: Bool { availability.hasCommands }

    public func start() {
        guard tasks.isEmpty else { return }
        let data = self.data
        tasks.append(Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    self.accounts = list
                    if self.account == nil || !list.contains(where: { $0.id == self.account }) { self.account = list.first?.id }
                }
            } catch {}
        })
    }

    private func accountChanged() {
        splitsTask?.cancel()
        for task in countsTasks { task.cancel() }
        countsTasks = []
        splits = []
        otherUnread = nil
        otherTotal = nil
        hiddenWhenEmpty = []
        alsoShownInInbox = []
        splitsLoaded = false
        legacyMigrationDone = false
        eventsChange = nil
        eventsNote = nil
        latestCounts = nil
        latestLabels = []
        draft = nil
        preview = nil
        guard let account else { return }
        let data = self.data
        splitsTask = Task { [weak self] in
            do {
                for try await list in data.splits(account) {
                    guard !Task.isCancelled else { return }
                    self?.splits = list.sorted { $0.position < $1.position }
                    self?.splitsLoaded = true
                    self?.updateOther()
                    await self?.migrateLegacyPresetSplits()
                }
            } catch {}
        }
        countsTasks = [
            Task { [weak self] in
                do {
                    for try await counts in data.counts(account) {
                        guard !Task.isCancelled else { return }
                        self?.latestCounts = counts
                        self?.updateOther()
                    }
                } catch {}
            },
            Task { [weak self] in
                do {
                    for try await labels in data.labels(account) {
                        guard !Task.isCancelled else { return }
                        self?.latestLabels = labels
                        self?.updateOther()
                    }
                } catch {}
            },
        ]
        if let settings {
            let key = AppSettings.hideSplitWhenEmpty(account)
            countsTasks.append(Task { [weak self] in
                for await list in settings.observe(key) {
                    guard !Task.isCancelled else { return }
                    self?.hiddenWhenEmpty = Set(list)
                }
            })
            let alsoShow = AppSettings.alsoShowSplitInInbox(account)
            countsTasks.append(Task { [weak self] in
                for await list in settings.observe(alsoShow) {
                    guard !Task.isCancelled else { return }
                    self?.alsoShownInInbox = Set(list)
                }
            })
        }
    }

    private func updateOther() {
        otherUnread = latestCounts?.otherUnread
        otherTotal = latestCounts?.otherTotal(labels: latestLabels, splits: splits)
    }

    public var canHideWhenEmpty: Bool { availability.canEditSettings && settings != nil }

    public func isHiddenWhenEmpty(_ split: SplitInfo) -> Bool { hiddenWhenEmpty.contains(split.id.rawValue) }
    public var isOtherHiddenWhenEmpty: Bool { hiddenWhenEmpty.contains(AppSettings.otherSplitToken) }

    public func setHiddenWhenEmpty(_ split: SplitInfo, _ hidden: Bool) async { await setHidden(split.id.rawValue, hidden) }
    public func setOtherHiddenWhenEmpty(_ hidden: Bool) async { await setHidden(AppSettings.otherSplitToken, hidden) }

    private func setHidden(_ token: String, _ hidden: Bool) async {
        guard canHideWhenEmpty, let account, let settings else { return }
        var next = hiddenWhenEmpty
        if hidden { next.insert(token) } else { next.remove(token) }
        let previous = hiddenWhenEmpty
        hiddenWhenEmpty = next
        errorMessage = nil
        do { try await settings.set(AppSettings.hideSplitWhenEmpty(account), next.sorted()) } catch {
            hiddenWhenEmpty = previous
            errorMessage = Self.message(error)
        }
    }

    public static let alsoShowNote = "Also show in Important/Other keeps this split's conversations in the Important or "
        + "Other tab too. Important conversations are always in Important."

    public var canSetAlsoShow: Bool { canHideWhenEmpty }

    public func isAlsoShownInInbox(_ split: SplitInfo) -> Bool { alsoShownInInbox.contains(split.id.rawValue) }

    public func setAlsoShownInInbox(_ split: SplitInfo, _ on: Bool) async {
        guard canSetAlsoShow, let account, let settings else { return }
        var next = alsoShownInInbox
        if on { next.insert(split.id.rawValue) } else { next.remove(split.id.rawValue) }
        let previous = alsoShownInInbox
        alsoShownInInbox = next
        errorMessage = nil
        do { try await settings.set(AppSettings.alsoShowSplitInInbox(account), next.sorted()) } catch {
            alsoShownInInbox = previous
            errorMessage = Self.message(error)
        }
    }

    public enum EventsChange: Equatable, Sendable {
        case added(SplitKey)
        case upgraded(SplitKey, oldRuleText: String)
    }

    public var eventsOffer: EventsTabOffer? {
        guard canEdit, account != nil, splitsLoaded, commands != nil else { return nil }
        return EventsTabOffer.offer(for: splits)
    }

    public func acceptEventsOffer() async {
        guard let offer = eventsOffer, let account, let commands else { return }
        errorMessage = nil
        do {
            switch offer {
            case .add(let name):
                let key = try await commands.upsertSplit(SplitDefinition(account: account, name: name,
                                                                         ruleText: EventsTabOffer.ruleText))
                eventsChange = .added(key)
                if canHideWhenEmpty, !hiddenWhenEmpty.contains(key.rawValue) { await setHidden(key.rawValue, true) }
            case .upgrade(let split):
                _ = try await commands.upsertSplit(SplitDefinition(account: account, id: split.id, name: split.name,
                                                                   ruleText: EventsTabOffer.ruleText,
                                                                   enabled: split.enabled))
                eventsChange = .upgraded(split.id, oldRuleText: split.ruleText)
            }
            eventsNote = offer.doneTitle
        } catch {
            errorMessage = Self.message(error)
        }
    }

    public func undoEventsChange() async {
        guard canEdit, let change = eventsChange, let account, let commands else { return }
        errorMessage = nil
        do {
            switch change {
            case .added(let key):
                try await commands.deleteSplit(account, key)
                if hiddenWhenEmpty.contains(key.rawValue) { await setHidden(key.rawValue, false) }
            case .upgraded(let key, let old):
                guard let split = splits.first(where: { $0.id == key }) else { break }
                _ = try await commands.upsertSplit(SplitDefinition(account: account, id: key, name: split.name,
                                                                   ruleText: old, enabled: split.enabled))
            }
            eventsChange = nil
            eventsNote = "Undone"
        } catch {
            errorMessage = Self.message(error)
        }
    }

    public var canRescanEvents: Bool { canHideWhenEmpty && account != nil }

    public func rescanEvents(now: Date = Date()) async {
        guard canRescanEvents, let account, let settings else { return }
        errorMessage = nil
        do {
            try await settings.set(AppSettings.eventsRescanAt(account), Int((now.timeIntervalSince1970 * 1000).rounded()))
        } catch {
            errorMessage = Self.message(error)
            return
        }
        eventsNote = "Re-scanned. Invitations found by the next syncs appear on their own."
        try? await data.refresh(account)
    }

    func migrateLegacyPresetSplits() async {
        guard !legacyMigrationDone, canEdit, let account, let commands else { return }
        legacyMigrationDone = true
        _ = await SplitPresetMigration.upgrade(splits, account: account, commands: commands)
    }

    public var presets: [SplitPreset] { SplitPresets.all }

    public var presetsUnavailableReason: String? { availability.storedItemsNote }

    public func existingSplit(for preset: SplitPreset) -> SplitInfo? {
        if preset.needsDomain { return nil }
        return splits.first { $0.ruleText.caseInsensitiveCompare(preset.ruleText) == .orderedSame }
    }

    public func beginPreset(_ preset: SplitPreset) {
        guard canEdit else { return }
        draft = Draft(id: nil, name: preset.name, ruleText: preset.ruleText, enabled: true)
        errorMessage = nil
        updatePreview()
    }

    public func beginAdd() {
        guard canEdit else { return }
        draft = Draft(id: nil, name: "", ruleText: "", enabled: true)
        preview = nil
        errorMessage = nil
    }

    public func beginEdit(_ split: SplitInfo) {
        guard canEdit else { return }
        draft = Draft(id: split.id, name: split.name, ruleText: split.ruleText, enabled: split.enabled)
        errorMessage = nil
        updatePreview()
    }

    public func cancelEdit() {
        draft = nil
        preview = nil
        previewTask?.cancel()
    }

    public func updatePreview() {
        previewTask?.cancel()
        guard let account, let rule = draft?.ruleText.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty else {
            preview = nil
            return
        }
        let data = self.data
        let limit = Self.previewLimit
        previewTask = Task { [weak self] in
            do {
                var count = 0
                var more = false
                for try await page in data.search(rule, accounts: [account], limit: limit) {
                    count = page.hits.count
                    more = page.hasMore
                    break
                }
                guard !Task.isCancelled else { return }
                self?.preview = Self.previewText(count: count, more: more)
            } catch {
                guard !Task.isCancelled else { return }
                self?.preview = (error as? MailPortError)?.description ?? "That rule can't be read."
            }
        }
    }

    static func previewText(count: Int, more: Bool) -> String {
        if more { return "Matches \(count)+ conversations" }
        return count == 1 ? "Matches 1 conversation" : "Matches \(count) conversations"
    }

    public var canSave: Bool {
        guard canEdit, let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.ruleText.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.ruleText.trimmingCharacters(in: .whitespaces).hasSuffix("@")
    }

    public func save() async {
        guard canSave, let account, let draft, let commands else { return }
        errorMessage = nil
        do {
            _ = try await commands.upsertSplit(SplitDefinition(
                account: account, id: draft.id, name: draft.name.trimmingCharacters(in: .whitespaces),
                ruleText: draft.ruleText.trimmingCharacters(in: .whitespaces), enabled: draft.enabled))
            self.draft = nil
            preview = nil
        } catch {
            errorMessage = Self.message(error)
        }
    }

    public func delete(_ split: SplitInfo) async {
        guard canEdit, let commands else { return }
        errorMessage = nil
        do { try await commands.deleteSplit(split.account, split.id) } catch { errorMessage = Self.message(error) }
    }

    public func move(from source: IndexSet, to destination: Int) async {
        guard canEdit, let account, let commands else { return }
        var order = splits.map(\.id)
        let moving = source.sorted().map { order[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { order.remove(at: index) }
        order.insert(contentsOf: moving, at: destination - before)
        guard order != splits.map(\.id) else { return }
        errorMessage = nil
        do { try await commands.reorderSplits(account, order) } catch { errorMessage = Self.message(error) }
    }

    static func message(_ error: Error) -> String {
        (error as? MailPortError)?.description ?? "That change couldn't be saved."
    }
}
