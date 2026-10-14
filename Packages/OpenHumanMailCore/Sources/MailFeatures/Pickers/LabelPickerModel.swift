import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class LabelPickerModel {
    public enum CheckState: Sendable, Hashable {
        case off, on, mixed
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case label(LabelInfo)
            case create(name: String)
            case place(MovePlace)
            case split(SplitInfo, label: LabelInfo?)
            case addSender(SplitInfo, SplitRuleChoice)
        }

        public enum Section: String, Hashable, Sendable, CaseIterable {
            case places = "Places"
            case splits = "Splits"
            case labels = "Labels"
        }

        public let id: String
        public let kind: Kind
        public let title: String
        public let parentPath: String?
        public let check: CheckState?
        public let matched: [Int]
        public var section: Section? = nil
        public var disabledReason: String? = nil
        public var tag: String? = nil

        public var isEnabled: Bool { disabledReason == nil }
    }

    public let mode: LabelPickerMode
    public let targets: [ThreadKey]
    public let account: AccountID?
    public var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    public private(set) var rows: [Row] = []
    public private(set) var cursor = 0
    public private(set) var isClosed = false

    @ObservationIgnored private let allLabels: [LabelInfo]
    @ObservationIgnored private let appliedCount: [Int64: Int]
    @ObservationIgnored private var toggled: [Int64: Bool] = [:]
    @ObservationIgnored private let actions: LabelPickerActions
    public let move: MoveOptions?

    public init(mode: LabelPickerMode, targets: [ThreadKey], account: AccountID?, labels: [LabelInfo],
                targetRows: [ThreadRow], actions: LabelPickerActions, move: MoveOptions? = nil) {
        self.mode = mode
        self.move = mode == .move ? move : nil
        self.targets = targets
        self.account = account
        self.allLabels = labels.filter { $0.kind == .user && !$0.isHidden && !$0.name.hasPrefix(OHGmailLabels.root + "/") }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var counts: [Int64: Int] = [:]
        for row in targetRows where targets.contains(row.id) {
            for id in row.userLabelIDs { counts[id, default: 0] += 1 }
        }
        self.appliedCount = counts
        self.actions = actions
        refresh()
    }

    public var title: String { mode == .move ? "Move to…" : mode == .navigate ? "Go to label…" : "Label as…" }
    public var placeholder: String { title }

    public func check(of label: LabelInfo) -> CheckState {
        if let on = toggled[label.id] { return on ? .on : .off }
        let applied = appliedCount[label.id] ?? 0
        if applied == 0 || targets.isEmpty { return .off }
        return applied >= targets.count ? .on : .mixed
    }

    private func refresh() {
        let matcher = FuzzyMatcher(query)
        var result: [Row] = []
        var taken = Set<Int64>()
        if let move {
            result += placeRows(move, matcher)
            result += splitRows(move, matcher, taken: &taken)
        }
        let section: Row.Section? = move == nil ? nil : .labels
        var scored: [(Row, Int)] = []
        let recent = matcher.isEmpty ? move?.recentLabelIDs ?? [] : []
        let listed = recent.isEmpty ? allLabels : MoveToSuperset.recentFirst(allLabels, recent: recent)
        for label in listed where !taken.contains(label.id) {
            var matched: [Int] = []
            var score = 0
            if !matcher.isEmpty {
                guard let m = matcher.match(label.name) else { continue }
                let shift = label.name.count - label.displayName.count
                matched = m.positions.compactMap { $0 >= shift ? $0 - shift : nil }
                score = m.score
            }
            let parts = label.name.split(separator: "/").map(String.init)
            let path = parts.count > 1 ? parts.dropLast().joined(separator: " / ") + " / " : nil
            let row = Row(id: "label.\(label.id)", kind: .label(label), title: label.displayName, parentPath: path,
                          check: mode == .label ? check(of: label) : nil, matched: matched, section: section)
            scored.append((row, score))
        }
        result += matcher.isEmpty ? scored.map(\.0) : scored.enumerated().sorted {
            $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset
        }.map(\.element.0)
        let name = query.trimmingCharacters(in: .whitespaces)
        if mode != .navigate, !name.isEmpty, account != nil, !SuperhumanLabels.isSuperhuman(name),
           !allLabels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame
               || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            result.append(Row(id: "create", kind: .create(name: name), title: "Create label “\(name)”", parentPath: nil,
                              check: nil, matched: [], section: section))
        }
        rows = result
        cursor = result.firstIndex(where: \.isEnabled) ?? 0
    }

    private func placeRows(_ move: MoveOptions, _ matcher: FuzzyMatcher) -> [Row] {
        move.places.compactMap { option in
            guard let m = matcher.match(option.place.title) else { return nil }
            return Row(id: "place.\(option.place.rawValue)", kind: .place(option.place), title: option.place.title,
                       parentPath: nil, check: nil, matched: m.positions, section: .places,
                       disabledReason: option.disabledReason)
        }
    }

    private func splitRows(_ move: MoveOptions, _ matcher: FuzzyMatcher, taken: inout Set<Int64>) -> [Row] {
        var result: [Row] = []
        for split in MoveToSuperset.listedSplits(move.splits) {
            let label = MoveToSuperset.label(for: split, in: allLabels)
            if let label { taken.insert(label.id) }
            guard let m = matcher.match(title: split.name, keywords: label.map { [$0.name] } ?? []) else { continue }
            result.append(Row(id: "split.\(split.id.rawValue)", kind: .split(split, label: label), title: split.name,
                              parentPath: nil, check: nil, matched: m.positions, section: .splits,
                              disabledReason: label == nil ? MoveToSuperset.ruleSplitReason : nil,
                              tag: MoveToSuperset.splitTag))
            if label == nil, let sender = move.sender, AddToSplit.canAddSafely(to: split) {
                result.append(Row(id: "split.\(split.id.rawValue).addSender", kind: .addSender(split, sender),
                                  title: "Add this sender to \(split.name)", parentPath: nil, check: nil, matched: [],
                                  section: .splits))
            }
        }
        return result
    }

    public func header(before index: Int) -> String? {
        guard rows.indices.contains(index), let section = rows[index].section else { return nil }
        return index == 0 || rows[index - 1].section != section ? section.rawValue : nil
    }

    public func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        var next = cursor
        for _ in rows.indices {
            next = ((next + delta) % rows.count + rows.count) % rows.count
            if rows[next].isEnabled {
                cursor = next
                return
            }
        }
    }

    public func toggleCursor() {
        guard mode == .label, rows.indices.contains(cursor), case .label(let label) = rows[cursor].kind else { return }
        toggled[label.id] = check(of: label) != .on
        refresh(keepingCursor: cursor)
    }

    private func refresh(keepingCursor index: Int) {
        refresh()
        cursor = min(index, max(rows.count - 1, 0))
    }

    public var changes: (add: [LabelInfo], remove: [LabelInfo]) {
        var add: [LabelInfo] = [], remove: [LabelInfo] = []
        for label in allLabels {
            guard let on = toggled[label.id] else { continue }
            let applied = appliedCount[label.id] ?? 0
            if on { add.append(label) } else if applied > 0 { remove.append(label) }
        }
        return (add, remove)
    }

    public func confirm() {
        guard !isClosed, rows.indices.contains(cursor) else { return }
        let row = rows[cursor]
        guard row.isEnabled else { return }
        switch row.kind {
        case .create(let name):
            finish { $0.create(name) }
        case .place(let place):
            finish { $0.moveToPlace(place) }
        case .split(let split, let label?):
            finish { $0.moveToSplit(split, label) }
        case .split(_, .none):
            return
        case .addSender(let split, let sender):
            finish { $0.addSenderToSplit(split, sender) }
        case .label(let label):
            switch mode {
            case .label:
                var (add, remove) = changes
                if toggled[label.id] == nil, check(of: label) == .off { add.append(label) }
                finish { $0.setLabels(add, remove) }
            case .move:
                finish { $0.move(label) }
            case .navigate:
                finish { $0.navigate(label) }
            }
        }
    }

    public func choose(_ row: Row) {
        guard row.isEnabled, let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        cursor = index
        if mode == .label, case .label = row.kind { toggleCursor() } else { confirm() }
    }

    public func close() { isClosed = true }

    private func finish(_ body: @MainActor (LabelPickerActions) -> Void) {
        isClosed = true
        body(actions)
    }
}

public struct LabelPickerActions {
    public var setLabels: @MainActor (_ add: [LabelInfo], _ remove: [LabelInfo]) -> Void
    public var move: @MainActor (LabelInfo) -> Void
    public var create: @MainActor (String) -> Void
    public var navigate: @MainActor (LabelInfo) -> Void
    public var moveToPlace: @MainActor (MovePlace) -> Void
    public var moveToSplit: @MainActor (SplitInfo, LabelInfo) -> Void
    public var addSenderToSplit: @MainActor (SplitInfo, SplitRuleChoice) -> Void

    public init(setLabels: @escaping @MainActor ([LabelInfo], [LabelInfo]) -> Void,
                move: @escaping @MainActor (LabelInfo) -> Void, create: @escaping @MainActor (String) -> Void,
                navigate: @escaping @MainActor (LabelInfo) -> Void,
                moveToPlace: @escaping @MainActor (MovePlace) -> Void = { _ in },
                moveToSplit: @escaping @MainActor (SplitInfo, LabelInfo) -> Void = { _, _ in },
                addSenderToSplit: @escaping @MainActor (SplitInfo, SplitRuleChoice) -> Void = { _, _ in }) {
        self.setLabels = setLabels
        self.move = move
        self.create = create
        self.navigate = navigate
        self.moveToPlace = moveToPlace
        self.moveToSplit = moveToSplit
        self.addSenderToSplit = addSenderToSplit
    }
}
