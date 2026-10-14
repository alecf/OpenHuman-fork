import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ClassificationRuleSetTests {
    typealias F = AutoLabelFixture

    static let rule = ClassificationRule(id: "user.list", title: "The example list is News",
                                         when: .fact(.listID, "contains", .text("letters.example")), then: .setLabel(.news))

    @Test func anEmptyStoreStartsAtTheShippedVersionAndEveryChangeIsAVersion() async throws {
        let f = F(writes: false)
        let set = f.env.classification
        await set.load()
        #expect(set.version == 1 && set.config == .shipped)
        #expect(await set.add(Self.rule))
        #expect(await set.setEnabled(ruleID: Self.rule.id, false))
        #expect(await set.setDefault(DefaultRules.withYou, enabled: false))
        #expect(await set.setDefault(DefaultRules.bulkNeverRespond, params: RuleParams(massRecipients: 4)))
        #expect(set.version == 5)
        let history = await set.history()
        #expect(history.map(\.version) == [5, 4, 3, 2, 1] && history.last?.origin == "default")
        #expect(set.config.defaultRule(DefaultRules.bulkNeverRespond)?.edited == true)
        #expect(await set.setDefault(DefaultRules.bulkNeverRespond, params: nil))
        #expect(set.config.defaultRule(DefaultRules.bulkNeverRespond)?.edited == false)
    }

    @Test func undoAndRedoWriteNewVersions() async throws {
        let f = F(writes: false)
        let set = f.env.classification
        #expect(await set.add(Self.rule))
        let undo = try #require(f.env.undo)
        #expect(undo.stack.count == 1)
        await undo.undoLast()
        #expect(set.config.rules.isEmpty && set.version == 3)
        await undo.redoLast()
        #expect(set.config.rules == [Self.rule] && set.version == 4)
        #expect(await set.history().first?.origin == "revert")
    }

    @Test func aChangeWorksInReadOnlySafeMode() async throws {
        let f = F(safeMode: .readOnly, writes: true)
        #expect(await f.env.classification.add(Self.rule))
        #expect(f.env.classification.config.rules.count == 1)
    }

    @Test func historyIsBoundedAndAStoredHeadIsRead() async throws {
        let store = InMemoryClassificationRulesStore()
        let config = ClassificationConfig(rules: [Self.rule])
        for n in 1...5 {
            _ = try await store.append(origin: "edit", bodyJSON: try config.json(), digest: config.digest, note: "\(n)",
                                       createdAt: fixedNow, historyLimit: 3)
        }
        #expect(try await store.versions(limit: 10).map(\.version) == [5, 4, 3])
        let set = ClassificationRuleSet(environment: nil, store: store)
        await set.load()
        #expect(set.version == 5 && set.config == config)
    }

    @Test func examplesAreBoundedAndClear() async throws {
        let store = InMemoryClassificationRulesStore()
        for n in 0..<5 {
            try await store.addExample(LabelledExample(id: "e\(n)", createdAt: fixedNow.addingTimeInterval(Double(n)),
                                                       expected: "news"), maxRows: 3)
        }
        #expect(try await store.examples(limit: 10).map(\.id) == ["e4", "e3", "e2"])
        try await store.deleteExample(id: "e3")
        #expect(try await store.examples(limit: 10).map(\.id) == ["e4", "e2"])
        try await store.removeAllExamples()
        #expect(try await store.examples(limit: 10).isEmpty)
    }

    @Test func learnFromMyCorrectionsOffKeepsNoExample() async throws {
        let f = F(writes: false)
        try await f.store.set(AppSettings.classificationTeachFromCorrections, false)
        #expect(!(await f.env.classification.record(LabelledExample(createdAt: fixedNow, expected: "news"))))
        #expect(await f.env.classification.examples().isEmpty)
    }
}
