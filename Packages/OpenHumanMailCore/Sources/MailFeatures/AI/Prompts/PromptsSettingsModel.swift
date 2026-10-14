import Foundation
import Observation
import OpenHumanAI

@MainActor @Observable
public final class PromptsSettingsModel {
    public struct Row: Identifiable, Hashable, Sendable {
        public let info: PromptInfo
        public let version: Int
        public var activeRevision: Int?
        public var activeBaseVersion: Int?
        public var revisionCount: Int

        public var id: String { info.id }
        public var badge: String? { activeRevision.map { String(localized: "Edited · r\($0)") } }
        public var isBasedOnOlderDefault: Bool { activeBaseVersion.map { $0 < version } ?? false }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public let group: PromptInfo.Group
        public let rows: [Row]
        public var id: String { group.rawValue }
        public var title: String { PromptsSettingsModel.title(group) }
    }

    public enum EditorTab: String, CaseIterable, Sendable {
        case mine, original, changes, history
    }

    public enum TestState: Equatable, Sendable {
        case idle
        case running
        case done(PromptTestResult)
        case failed(String)
    }

    public typealias DiffLine = PromptDiff.Line
    public typealias Revision = PromptRevision

    public typealias Tester = @MainActor (PromptInfo, String?) async throws -> PromptTestResult

    public private(set) var rows: [Row] = []
    public private(set) var selectedID: String?
    public var draft = ""
    public var note = ""
    public var tab: EditorTab = .mine
    public private(set) var history: [PromptRevision] = []
    public private(set) var test: TestState = .idle
    public private(set) var error: String?
    public private(set) var missingPrompt: String?

    @ObservationIgnored public let registry: PromptRegistry
    @ObservationIgnored let tester: Tester?

    public init(registry: PromptRegistry, tester: Tester? = nil) {
        self.registry = registry
        self.tester = tester
    }


    public var sections: [Section] {
        PromptInfo.Group.allCases.compactMap { group in
            let rows = rows.filter { $0.info.group == group }
            return rows.isEmpty ? nil : Section(group: group, rows: rows)
        }
    }

    public func load() async {
        let counts = (try? await registry.revisionCounts()) ?? [:]
        let active = registry.provider.overrides
        rows = PromptCatalog.entries.compactMap { info in
            guard let bundled = try? registry.bundled(info.id) else { return nil }
            return Row(info: info, version: bundled.id.version, activeRevision: active[info.id]?.revision,
                       activeBaseVersion: active[info.id]?.baseVersion, revisionCount: counts[info.id] ?? 0)
        }
    }


    public var selected: Row? { rows.first { $0.id == selectedID } }

    public var originalText: String {
        guard let selectedID, let template = try? registry.bundled(selectedID) else { return "" }
        return template.body
    }

    public var activeText: String {
        guard let selectedID else { return "" }
        return registry.activeOverride(selectedID)?.body ?? originalText
    }

    public var hasChanges: Bool { selectedID != nil && draft != activeText }

    public var check: PromptCheck {
        guard let info = selected?.info else { return PromptCheck() }
        return PromptCheck.of(draft, for: info)
    }

    public var canSave: Bool { hasChanges && check.canSave }

    public var changes: [PromptDiff.Line] { PromptDiff.lines(from: originalText, to: draft) }

    public var identity: String {
        guard let selectedID, let template = try? registry.provider.current.template(named: selectedID) else { return "" }
        return template.identity
    }

    public var deepLink: String? { selectedID.map { "openhuman://settings/ai/prompts/" + $0 } }

    public var canTest: Bool { tester != nil && selected?.info.threadTest != nil }

    public func select(_ id: String) async {
        if rows.isEmpty { await load() }
        guard rows.contains(where: { $0.id == id }) else {
            missingPrompt = id
            selectedID = nil
            return
        }
        missingPrompt = nil
        selectedID = id
        tab = .mine
        error = nil
        note = ""
        test = .idle
        draft = activeText
        history = (try? await registry.history(id)) ?? []
    }

    public func closeEditor() {
        selectedID = nil
        draft = ""
        history = []
        test = .idle
        error = nil
    }

    public func open(promptID: String) async {
        guard !promptID.isEmpty else {
            closeEditor()
            missingPrompt = nil
            await load()
            return
        }
        await select(promptID)
    }

    public func startFromOriginal() { draft = originalText }

    public func discardChanges() { draft = activeText }

    public func save() async {
        guard let selectedID, canSave else { return }
        let note = self.note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await registry.save(selectedID, body: draft, note: note.isEmpty ? nil : note)
            self.note = ""
            await refresh(selectedID)
        } catch {
            self.error = Self.message(error)
        }
    }

    public func resetToOriginal() async {
        guard let selectedID else { return }
        do {
            try await registry.reset(selectedID)
            await refresh(selectedID)
            draft = activeText
        } catch {
            self.error = Self.message(error)
        }
    }

    public func revert(to revision: Int) async {
        guard let selectedID else { return }
        do {
            try await registry.revert(selectedID, to: revision)
            await refresh(selectedID)
            draft = activeText
            tab = .mine
        } catch {
            self.error = Self.message(error)
        }
    }

    public func runTest() async {
        guard let tester, let info = selected?.info else { return }
        test = .running
        do {
            let result = try await tester(info, draft == activeText ? nil : draft)
            test = .done(result)
        } catch let failure as PromptTestError {
            test = .failed(Self.message(failure))
        } catch {
            test = .failed(Self.message(error))
        }
    }

    private func refresh(_ id: String) async {
        await load()
        history = (try? await registry.history(id)) ?? []
        error = nil
        draft = draft == "" ? activeText : draft
    }


    public nonisolated static func title(_ group: PromptInfo.Group) -> String {
        switch group {
        case .summaries: String(localized: "Summaries")
        case .replies: String(localized: "Replies and writing")
        case .composer: String(localized: "⌘J presets")
        case .sorting: String(localized: "Sorting and labels")
        case .search: String(localized: "Search and Ask AI")
        case .scheduling: String(localized: "Scheduling")
        case .followUps: String(localized: "Follow-ups")
        case .shared: String(localized: "Used by every prompt")
        }
    }

    public nonisolated static func title(_ tab: EditorTab) -> String {
        switch tab {
        case .mine: String(localized: "Your version")
        case .original: String(localized: "Default")
        case .changes: String(localized: "Changes")
        case .history: String(localized: "History")
        }
    }

    public nonisolated static func message(_ problem: PromptProblem) -> String {
        switch problem {
        case .empty: String(localized: "The prompt is empty.")
        case .tooLarge(let bytes): String(localized: "The prompt is too long to keep (\(bytes / 1024) KB; the limit is 256 KB).")
        case .unknownSlot(let slot): String(localized: "{{\(slot)}} isn't filled in for this prompt. Remove it or use one of the slots listed.")
        case .unclosedSlot: String(localized: "A {{ has no closing }}.")
        }
    }

    public nonisolated static func message(_ warning: PromptWarning) -> String {
        switch warning {
        case .noJSONForm: String(localized: "The answer is read as JSON, and your text no longer shows the JSON form. The feature may fail; Test on this thread first.")
        case .injectionPolicy: String(localized: "This is the injection policy. Email text is always fenced with a nonce whatever this says.")
        case .missingSlot(let slot): String(localized: "Your text doesn't use {{\(slot)}}, so what the app puts there won't reach the model.")
        }
    }

    public nonisolated static func message(_ failure: PromptTestError) -> String {
        switch failure {
        case .noConversation: String(localized: "Open a conversation in the mail window first.")
        case .notTestable: String(localized: "This prompt isn't used on a conversation.")
        case .failed(let reason): reason
        }
    }

    nonisolated static func message(_ error: any Error) -> String {
        if let error = error as? PromptRegistryError {
            switch error {
            case .unknownPrompt(let id): return String(localized: "No prompt “\(id)”.")
            case .refused(let problems): return problems.map(message).joined(separator: " ")
            }
        }
        return String(localized: "Couldn't save the prompt on this Mac.")
    }
}
