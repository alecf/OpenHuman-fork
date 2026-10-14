import Foundation
import Observation
import OpenHumanLinks

@MainActor
@Observable
public final class DevChecklistModel {
    public struct Section: Identifiable, Sendable, Hashable {
        public var id: String { area }
        public let area: String
        public let items: [DevChecklistItem]
    }

    public enum OpenOutcome: Equatable, Sendable {
        case followed(MailLink, message: String)
        case showKeys([String])
        case invalidLink
    }

    public private(set) var checklist: DevChecklist
    public private(set) var answers: [String: DevChecklistAnswer]
    public var showOnlyUntested = false
    public var viewingItemID: String?
    public private(set) var openOutcomes: [String: OpenOutcome] = [:]
    public private(set) var saveError: String?

    @ObservationIgnored public var linkHandler: ((MailLink) -> String)?
    @ObservationIgnored private let store: DevChecklistAnswerStore?
    @ObservationIgnored private let now: () -> Date

    public init(checklist: DevChecklist, store: DevChecklistAnswerStore?, now: @escaping () -> Date = Date.init) {
        self.checklist = checklist
        self.store = store
        self.now = now
        self.answers = store?.load() ?? [:]
    }

    public func reload(_ checklist: DevChecklist) {
        self.checklist = checklist
    }

    public var items: [DevChecklistItem] { checklist.items }

    public func answer(for id: String) -> DevChecklistAnswer? { answers[id] }

    public func isTested(_ id: String) -> Bool { answers[id]?.result != nil }

    public var testedCount: Int { checklist.items.filter { isTested($0.id) }.count }

    public var sections: [Section] {
        var order: [String] = []
        var byArea: [String: [DevChecklistItem]] = [:]
        for item in checklist.items where !(showOnlyUntested && isTested(item.id)) {
            if byArea[item.area] == nil { order.append(item.area) }
            byArea[item.area, default: []].append(item)
        }
        return order.map { Section(area: $0, items: byArea[$0] ?? []) }
    }

    public var viewingItem: DevChecklistItem? { viewingItemID.flatMap { id in checklist.items.first { $0.id == id } } }

    public func record(_ result: DevChecklistResult?, for id: String) {
        guard checklist.items.contains(where: { $0.id == id }) else { return }
        var answer = answers[id] ?? DevChecklistAnswer(itemID: id, result: nil, answeredAt: now())
        answer.result = result
        answer.answeredAt = now()
        answers[id] = answer
        viewingItemID = id
        persist()
    }

    public func setNote(_ note: String, for id: String) {
        guard checklist.items.contains(where: { $0.id == id }) else { return }
        let capped = String(note.prefix(DevChecklistAnswerStore.maxNote))
        var answer = answers[id] ?? DevChecklistAnswer(itemID: id, result: nil, answeredAt: now())
        guard answer.note != capped else { return }
        viewingItemID = id
        answer.note = capped
        answer.answeredAt = now()
        answers[id] = answer
        persist()
    }

    @discardableResult
    public func open(_ item: DevChecklistItem) -> OpenOutcome {
        viewingItemID = item.id
        let outcome: OpenOutcome
        if let text = item.deepLink {
            switch MailLinkParser.parse(string: text) {
            case .success(let link):
                outcome = .followed(link, message: linkHandler?(link) ?? "No mail window is open.")
            case .failure:
                outcome = .invalidLink
            }
        } else {
            outcome = .showKeys(item.steps)
        }
        openOutcomes[item.id] = outcome
        return outcome
    }

    public func answersToExport() -> [DevChecklistAnswer] {
        let order = Dictionary(uniqueKeysWithValues: checklist.items.enumerated().map { ($1.id, $0) })
        return answers.values.filter(\.needsExport).sorted { (order[$0.itemID] ?? .max, $0.itemID) < (order[$1.itemID] ?? .max, $1.itemID) }
    }

    public func markExported(_ ids: [String], at date: Date) {
        for id in ids { answers[id]?.exportedAt = date }
        persist()
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(answers)
            saveError = nil
        } catch {
            saveError = "Couldn't save the answers file."
        }
    }
}
