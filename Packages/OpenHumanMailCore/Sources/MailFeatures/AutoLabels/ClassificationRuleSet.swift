import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor @Observable
public final class ClassificationRuleSet {
    public nonisolated static let maxExamples = 10_000

    public private(set) var config: ClassificationConfig = .shipped
    public private(set) var version = 0
    public private(set) var isLoaded = false
    public private(set) var revision = 0
    public private(set) var errorMessage: String?
    public var pendingDraft: ClassificationRule?

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private(set) var store: any ClassificationRulesStoring
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var listeners: [@MainActor (ClassificationConfig) -> Void] = []
    @ObservationIgnored let now: @Sendable () -> Date

    public init(environment: AppEnvironment?, store: any ClassificationRulesStoring = InMemoryClassificationRulesStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.store = store
        self.now = now
    }

    public func use(store: any ClassificationRulesStoring) {
        guard !isLoaded, loading == nil else { return }
        self.store = store
    }

    public func onChange(_ listener: @escaping @MainActor (ClassificationConfig) -> Void) {
        listeners.append(listener)
    }


    public func load() async {
        if isLoaded { return }
        if let loading { return await loading.value }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.readHead()
        }
        loading = task
        await task.value
    }

    private func readHead() async {
        do {
            if let head = try await store.head(), let decoded = try? ClassificationConfig.decode(head.bodyJSON) {
                config = decoded
                version = head.version
            } else {
                let shipped = ClassificationConfig.shipped
                version = try await store.append(origin: "default", bodyJSON: try shipped.json(), digest: shipped.digest,
                                                 note: "Shipped rules, version \(DefaultRules.version)",
                                                 createdAt: now(), historyLimit: await historyLimit())
                config = shipped
            }
        } catch {
            errorMessage = String(localized: "Couldn't read your rules; using the shipped ones.")
        }
        isLoaded = true
    }

    private func historyLimit() async -> Int {
        let key = AppSettings.classificationRulesHistoryLimit
        return max(1, (try? await environment?.settings?.get(key)) ?? key.defaultValue)
    }


    @discardableResult
    public func apply(_ next: ClassificationConfig, title: LocalizedStringResource, origin: String = "edit",
                      note: String? = nil) async -> Bool {
        await load()
        guard next != config else { return true }
        let from = version
        guard let saved = await save(next, origin: origin, note: note ?? String(localized: title)) else { return false }
        let token = RuleSetUndo.token(from: saved, to: from)
        if let undo = environment?.undo {
            undo.push(UndoCoordinator.Entry(title: title, token: token, undoer: RuleSetUndo(ruleSet: self)))
        }
        return true
    }

    private func save(_ next: ClassificationConfig, origin: String, note: String?) async -> Int? {
        do {
            let number = try await store.append(origin: origin, bodyJSON: try next.json(), digest: next.digest, note: note,
                                                createdAt: now(), historyLimit: await historyLimit())
            config = next
            version = number
            errorMessage = nil
            revision += 1
            for listener in listeners { listener(next) }
            return number
        } catch {
            errorMessage = String(localized: "Couldn't save the rule change.")
            return nil
        }
    }

    func revert(token: UndoToken) async throws -> UndoToken? {
        let step = try RuleSetUndo.decode(token)
        guard let old = try await store.version(step.to) else { return nil }
        let body = try ClassificationConfig.decode(old.bodyJSON)
        guard let saved = await save(body, origin: "revert", note: String(localized: "Back to version \(step.to)")) else {
            throw MailPortError.unavailable("rules")
        }
        return RuleSetUndo.token(from: saved, to: step.from)
    }

    public func history(limit: Int = 50) async -> [RuleSetVersion] {
        (try? await store.versions(limit: limit)) ?? []
    }


    public func add(_ rule: ClassificationRule) async -> Bool {
        var next = config
        next.rules.append(rule)
        return await apply(next, title: "Added rule \u{201C}\(rule.title)\u{201D}")
    }

    public func update(_ rule: ClassificationRule) async -> Bool {
        var next = config
        guard let index = next.rules.firstIndex(where: { $0.id == rule.id }) else { return await add(rule) }
        next.rules[index] = rule
        return await apply(next, title: "Changed rule \u{201C}\(rule.title)\u{201D}")
    }

    public func delete(ruleID: String) async -> Bool {
        var next = config
        guard let rule = next.rules.first(where: { $0.id == ruleID }) else { return false }
        next.rules.removeAll { $0.id == ruleID }
        return await apply(next, title: "Deleted rule \u{201C}\(rule.title)\u{201D}")
    }

    public func setEnabled(ruleID: String, _ enabled: Bool) async -> Bool {
        var next = config
        guard let index = next.rules.firstIndex(where: { $0.id == ruleID }) else { return false }
        next.rules[index].enabled = enabled
        let title = next.rules[index].title
        return await apply(next, title: enabled ? "Turned on \u{201C}\(title)\u{201D}" : "Turned off \u{201C}\(title)\u{201D}")
    }

    public func move(ruleID: String, by offset: Int) async -> Bool {
        var next = config
        guard let index = next.rules.firstIndex(where: { $0.id == ruleID }) else { return false }
        let target = index + offset
        guard next.rules.indices.contains(target) else { return false }
        next.rules.swapAt(index, target)
        return await apply(next, title: "Moved rule \u{201C}\(next.rules[target].title)\u{201D}")
    }


    public func setDefault(_ id: String, enabled: Bool) async -> Bool {
        let title = config.defaultRule(id)?.title ?? id
        return await apply(config.settingDefault(id, enabled: enabled),
                           title: enabled ? "Turned on \u{201C}\(title)\u{201D}" : "Turned off \u{201C}\(title)\u{201D}")
    }

    public func setDefault(_ id: String, params: RuleParams?) async -> Bool {
        let title = config.defaultRule(id)?.title ?? id
        return await apply(config.settingDefault(id, params: params),
                           title: params == nil ? "Reset \u{201C}\(title)\u{201D}" : "Edited \u{201C}\(title)\u{201D}")
    }


    @discardableResult
    public func record(_ example: LabelledExample) async -> Bool {
        let settings = environment?.settings
        let teach = (try? await settings?.get(AppSettings.classificationTeachFromCorrections))
            ?? AppSettings.classificationTeachFromCorrections.defaultValue
        guard teach else { return false }
        let keepText = (try? await settings?.get(AppSettings.classificationKeepInputText))
            ?? AppSettings.classificationKeepInputText.defaultValue
        var kept = example
        if !keepText { kept.textJSON = nil }
        do {
            try await store.addExample(kept, maxRows: Self.maxExamples)
            revision += 1
            return true
        } catch {
            return false
        }
    }

    public func examples(limit: Int = 200) async -> [LabelledExample] {
        (try? await store.examples(limit: limit)) ?? []
    }

    public func deleteExample(id: String) async {
        try? await store.deleteExample(id: id)
        revision += 1
    }

    public func clearExamples() async {
        try? await store.removeAllExamples()
        revision += 1
    }
}

struct RuleSetUndo: MailUndoing {
    struct Step: Codable { var from: Int; var to: Int }

    let ruleSet: ClassificationRuleSet

    static func token(from: Int, to: Int) -> UndoToken {
        UndoToken(payload: (try? JSONEncoder().encode(Step(from: from, to: to))) ?? Data())
    }

    static func decode(_ token: UndoToken) throws -> Step {
        try JSONDecoder().decode(Step.self, from: token.payload)
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        try await ruleSet.revert(token: token)
    }
}
