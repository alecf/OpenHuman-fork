import Foundation
import Testing

@testable import AIEvalKit
@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct CorpusTests {
    @Test func theCorpusLoadsAndCoversEveryCategory() throws {
        let corpus = try EvalCorpus.load()
        #expect(corpus.count >= 48)
        #expect(Set(corpus.map(\.id)).count == corpus.count)
        for category in TriageCategory.allCases {
            #expect(corpus.filter { $0.category == category }.count >= 5, "too few \(category)")
        }
        #expect(corpus.allSatisfy { (0...3).contains($0.priority) })
        #expect(corpus.filter(\.isInjection).count >= 4)
    }

    @Test func theCorpusIsSyntheticOnly() throws {
        let reserved = #/@(?:[a-z0-9-]+\.)*example\.(?:com|net|org|jp)/#
        for email in try EvalCorpus.load() {
            #expect(email.from.contains(reserved), "\(email.id): sender \(email.from)")
            let addresses = email.body.matches(of: #/[A-Za-z0-9._-]+@[A-Za-z0-9.-]+/#).map { String($0.output) }
            for address in addresses { #expect(address.contains(reserved), "\(email.id): \(address)") }
            #expect(!email.body.lowercased().contains("gmail.com"))
        }
    }

    @Test func badLinesAreReportedWithTheirNumber() {
        #expect(throws: EvalCorpus.LoadError.badLine(2)) {
            try EvalCorpus.parse(#"{"id":"a","category":"fyi","priority":0,"subject":"s","from":"f","body":"b","tags":[]}"# + "\n{nope}\n")
        }
        #expect((try? EvalCorpus.parse("")) == [])
    }
}

@Suite struct StatsTests {
    @Test func percentilesUseNearestRank() {
        let values = (1...100).map(Double.init)
        #expect(EvalStats.percentile(values, 0.5) == 50)
        #expect(EvalStats.percentile(values, 0.95) == 95)
        #expect(EvalStats.percentile([7], 0.95) == 7)
        #expect(EvalStats.percentile([], 0.5) == 0)
        #expect(EvalStats.percentile([3, 1, 2], 1.0) == 3)
        #expect(EvalStats.mean([1, 2, 3]) == 2)
        #expect(EvalStats.mean([]) == 0)
    }
}

@Suite struct RunnerTests {
    private func oracle(_ corpus: [EvalEmail], flipping flipped: Set<String> = [], failing failed: Set<String> = []) -> FakeClassifier {
        let byKey = Dictionary(uniqueKeysWithValues: corpus.map { ("\($0.subject)|\($0.from)", $0) })
        return FakeClassifier(id: "fake.oracle", displayName: "Oracle") { input in
            let email = byKey["\(input.subject.text)|\(input.sender.text)"]
            guard let email else { return TriageResult(category: .other, priority: 0, reason: "") }
            if failed.contains(email.id) { throw AIError.timeout }
            let category: TriageCategory = flipped.contains(email.id) ? (email.category == .other ? .fyi : .other) : email.category
            return TriageResult(category: category, priority: email.priority, reason: "Fine.")
        }
    }

    @Test func aPerfectClassifierScoresOneHundredPercent() async throws {
        let corpus = try EvalCorpus.load()
        let report = await EvalRunner.run(classifier: oracle(corpus), corpus: corpus)
        #expect(report.total == corpus.count)
        #expect(report.answered == corpus.count)
        #expect(report.failed == 0)
        #expect(report.accuracy == 1)
        #expect(report.injectionAccuracy == 1)
        #expect(report.priorityWithinOne == 1)
        #expect(report.perCategory.allSatisfy { $0.precision == 1 && $0.recall == 1 && $0.f1 == 1 })
        #expect(report.perCategory.map(\.category) == TriageCategory.allCases.map(\.rawValue))
        #expect(report.latency.p50Milliseconds >= 0 && report.latency.p95Milliseconds >= report.latency.p50Milliseconds)
        #expect(report.injectionBehaviour.cases == InjectionCorpus.all.count)
        #expect(report.failureKinds.isEmpty)
    }

    @Test func wrongAnswersAndFailuresLowerTheScoresAndAreCounted() async throws {
        let corpus = try EvalCorpus.load()
        let flipped = Set(corpus.prefix(5).map(\.id))
        let failed = Set(corpus.dropFirst(5).prefix(3).map(\.id))
        let report = await EvalRunner.run(classifier: oracle(corpus, flipping: flipped, failing: failed), corpus: corpus)
        #expect(report.failed == 3)
        #expect(report.answered == corpus.count - 3)
        #expect(report.failureKinds == ["timeout": 3])
        let expected = Double(corpus.count - 5 - 3) / Double(corpus.count)
        #expect(abs(report.accuracy - expected) < 1e-9)
        #expect(report.confusion.values.reduce(0) { $0 + ($1["(failed)"] ?? 0) } == 3)
        let total = report.confusion.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        #expect(total == corpus.count)
    }

    @Test func perCategoryPrecisionAndRecallFollowTheConfusionMatrix() async throws {
        let corpus = [
            email("a", .receipt), email("b", .receipt), email("c", .receipt), email("d", .newsletter), email("e", .newsletter),
        ]
        let classifier = FakeClassifier(id: "fake.skewed") { input in
            let isNewsletter = input.subject.text == "d"
            return TriageResult(category: isNewsletter ? .receipt : (input.subject.text == "e" ? .newsletter : .receipt), priority: 0, reason: "")
        }
        let report = await EvalRunner.run(classifier: classifier, corpus: corpus, injectionCases: [])
        let receipt = try #require(report.perCategory.first { $0.category == "receipt" })
        #expect(receipt.support == 3 && receipt.predicted == 4 && receipt.truePositives == 3)
        #expect(abs(receipt.precision - 0.75) < 1e-9 && receipt.recall == 1)
        let newsletter = try #require(report.perCategory.first { $0.category == "newsletter" })
        #expect(newsletter.support == 2 && newsletter.predicted == 1 && newsletter.truePositives == 1)
        #expect(newsletter.precision == 1 && newsletter.recall == 0.5)
        #expect(abs(report.accuracy - 0.8) < 1e-9)
        #expect(report.confusion["newsletter"]?["receipt"] == 1)
    }

    @Test func suspiciousReasonsAreCountedInTheInjectionBehaviour() async {
        let classifier = FakeClassifier(id: "fake.blank") { _ in TriageResult(category: .other, priority: 0, reason: "") }
        let report = await EvalRunner.run(classifier: classifier, corpus: [], injectionCases: Array(InjectionCorpus.all.prefix(4)))
        #expect(report.injectionBehaviour.cases == 4)
        #expect(report.injectionBehaviour.blankedReasons == 4)
        #expect(report.injectionBehaviour.categories == ["other": 4])
        #expect(report.accuracy == 0)
    }

    @Test func errorKindsNeverCarryMessageText() {
        #expect(EvalRunner.kind(of: AIError.providerFailed("ZEBRA secret")) == "providerFailed")
        #expect(EvalRunner.kind(of: AIError.invalidOutput("ZEBRA")) == "invalidOutput")
        #expect(EvalRunner.kind(of: CancellationError()) == "cancelled")
        struct Other: Error {}
        #expect(EvalRunner.kind(of: Other()) == "error")
    }

    @Test func theReportRoundTripsThroughJSONAndPrintsASummary() async throws {
        let corpus = Array(try EvalCorpus.load().prefix(10))
        let report = await EvalRunner.run(classifier: oracle(corpus), corpus: corpus, injectionCases: [])
        let decoded = try JSONDecoder().decode(EvalReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(report.summary.contains("accuracy 100.0% over 10 emails"))
        #expect(report.summary.contains("needsReply"))
    }

    @Test func aLanguageModelProviderIsEvaluatedThroughTheTriagePrompt() async throws {
        let corpus = Array(try EvalCorpus.load().prefix(6))
        let scripted = ScriptedProvider(id: "fake.lm") { request, _ in
            let rendered = request.renderedInput()
            let category = rendered.contains("receipt") ? "receipt" : "other"
            return .text(#"{"category":"\#(category)","priority":1,"reason":"Fake."}"#)
        }
        let classifier = ProviderClassifier(wrapping: scripted, dataLocation: .onDevice)
        let report = await EvalRunner.run(classifier: classifier, corpus: corpus, injectionCases: [])
        #expect(report.answered == 6)
        let request = try #require(scripted.requests.first)
        #expect(request.task == .classify)
        #expect(request.output.schema == OutputGuard.triageSchema)
        #expect(request.untrusted.count == 3)
        let broken = ScriptedProvider(id: "fake.broken") { _, _ in .text("no json here") }
        let failed = await EvalRunner.run(classifier: ProviderClassifier(wrapping: broken, dataLocation: .onDevice), corpus: corpus, injectionCases: [])
        #expect(failed.failed == 6 && failed.failureKinds == ["invalidOutput": 6])
    }

    private func email(_ subject: String, _ category: TriageCategory) -> EvalEmail {
        EvalEmail(id: subject, category: category, priority: 0, subject: subject, from: "x <x@example.com>", body: "b", tags: [])
    }
}
