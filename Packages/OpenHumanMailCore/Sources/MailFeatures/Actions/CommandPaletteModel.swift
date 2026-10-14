import Foundation
import MailActions
import Observation

@MainActor @Observable
public final class CommandPaletteModel {
    public enum Group: String, Sendable, Hashable, CaseIterable {
        case top = "Top result"
        case actions = "Actions"
        case recent = "Recent"
        case suggested = "Suggested"
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public var id: ActionID { action }
        public let action: ActionID
        public let title: String
        public let keycaps: [String]
        public let group: Group
        public let matched: [Int]
        public let isDestructive: Bool
        let score: Int
    }

    public static let maxActions = 6
    public static let maxRecent = 5
    public static let maxSuggested = 6

    public private(set) var isOpen = false
    public var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var context: ActionContext?

    @ObservationIgnored private unowned let registry: ActionRegistry
    @ObservationIgnored private weak var host: (any ActionHost)?

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    public func open(host: (any ActionHost)?, context: ActionContext? = nil) {
        self.host = host
        self.context = context ?? host?.actionContext() ?? ActionContext()
        query = ""
        isOpen = true
        refresh()
    }

    public func close() {
        isOpen = false
        query = ""
        rows = []
        cursor = 0
        context = nil
        host = nil
    }

    public func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = (cursor + delta + rows.count) % rows.count
    }

    @discardableResult
    public func performSelected() -> Bool {
        guard rows.indices.contains(cursor) else { return false }
        return perform(rows[cursor].action)
    }

    @discardableResult
    public func perform(_ id: ActionID) -> Bool {
        guard isOpen, let context else { return false }
        let host = self.host
        close()
        return registry.perform(id, source: .palette, host: host, context: context)
    }

    func refresh() {
        guard isOpen, let context else { return }
        rows = Self.rank(query: query, descriptors: registry.descriptors, context: context, recents: registry.recents) {
            [registry, host] id in registry.availability(id, host: host, context: context).isEnabled
        }
        cursor = 0
    }

    public static func rank(query: String, descriptors: [ActionDescriptor], context: ActionContext,
                            recents: RecentActions, isAvailable: (ActionID) -> Bool) -> [Row] {
        let candidates = descriptors.filter { $0.appearsInPalette && isAvailable($0.id) }
        func row(_ d: ActionDescriptor, _ group: Group, _ match: FuzzyMatch?, score: Int) -> Row {
            Row(action: d.id, title: ActionRules.title(for: d, in: context),
                keycaps: d.defaultBindings.first?.keycaps ?? [], group: group, matched: match?.positions ?? [],
                isDestructive: d.isDestructive, score: score)
        }
        let matcher = FuzzyMatcher(query)
        guard !matcher.isEmpty else {
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            let recent = recents.recent(maxRecent).compactMap { byID[$0] }.map { row($0, .recent, nil, score: 0) }
            let shown = Set(recent.map(\.action))
            let suggested = candidates
                .filter { !shown.contains($0.id) && isSuggested($0, context) }
                .prefix(maxSuggested)
                .map { row($0, .suggested, nil, score: 0) }
            return recent + suggested
        }
        var scored: [Row] = []
        for descriptor in candidates {
            let title = ActionRules.title(for: descriptor, in: context)
            guard let match = matcher.match(title: title, keywords: descriptor.paletteKeywords + [descriptor.title])
            else { continue }
            scored.append(row(descriptor, .actions, match, score: match.score + recents.boost(descriptor.id)))
        }
        let ordered = scored.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
        guard let first = ordered.first else { return [] }
        let top = Row(action: first.action, title: first.title, keycaps: first.keycaps, group: .top,
                      matched: first.matched, isDestructive: first.isDestructive, score: first.score)
        return [top] + ordered.dropFirst().prefix(maxActions)
    }

    static func isSuggested(_ descriptor: ActionDescriptor, _ context: ActionContext) -> Bool {
        guard context.focusedThread != nil else { return descriptor.category == .navigation }
        if descriptor.id == .explainPlacement { return true }
        return descriptor.category == .thread && descriptor.module != .importance
            && !descriptor.id.rawValue.hasPrefix("selection.")
    }
}
