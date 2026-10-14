import Foundation
import OpenHumanAI
import OpenHumanAITesting

public enum EvalRunner {
    public static func run(
        classifier: any AIClassificationProvider, corpus: [EvalEmail], injectionCases: [InjectionCase] = InjectionCorpus.all,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> EvalReport {
        let clock = ContinuousClock()
        var correct = 0
        var answered = 0
        var withinOne = 0
        var latencies: [Double] = []
        var failureKinds: [String: Int] = [:]
        var confusion: [String: [String: Int]] = [:]
        var injectionTotal = 0
        var injectionCorrect = 0

        for (index, email) in corpus.enumerated() {
            if email.isInjection { injectionTotal += 1 }
            let start = clock.now
            do {
                let result = try await classifier.classify(email.classificationInput)
                latencies.append(milliseconds(clock.now - start))
                answered += 1
                confusion[email.category.rawValue, default: [:]][result.category.rawValue, default: 0] += 1
                if result.category == email.category {
                    correct += 1
                    if email.isInjection { injectionCorrect += 1 }
                }
                if abs(result.priority - email.priority) <= 1 { withinOne += 1 }
            } catch {
                latencies.append(milliseconds(clock.now - start))
                failureKinds[kind(of: error), default: 0] += 1
                confusion[email.category.rawValue, default: [:]]["(failed)", default: 0] += 1
            }
            progress?(index + 1, corpus.count)
        }

        var injection = EvalReport.InjectionBehaviour(cases: 0, errors: 0, blankedReasons: 0, categories: [:])
        for attack in injectionCases {
            let input = ClassificationInput.make(
                from: AIThreadInput(
                    threadKey: "inject-\(attack.id)", subject: attack.subject,
                    messages: [
                        AIMessageInput(
                            messageKey: "inject-\(attack.id)-m1", from: attack.from, date: Date(timeIntervalSince1970: 1_790_000_000),
                            bodyText: attack.body, subject: attack.subject)
                    ]))
            injection.cases += 1
            do {
                let result = try await classifier.classify(input)
                injection.categories[result.category.rawValue, default: 0] += 1
                if result.reason.isEmpty { injection.blankedReasons += 1 }
            } catch {
                injection.errors += 1
            }
        }

        return EvalReport(
            providerID: classifier.id.rawValue, displayName: classifier.displayName, modelVersion: await classifier.modelVersion(),
            dataLocation: describe(classifier.dataLocation), total: corpus.count, answered: answered,
            failed: corpus.count - answered, failureKinds: failureKinds,
            accuracy: EvalStats.ratio(correct, corpus.count),
            injectionAccuracy: injectionTotal == 0 ? nil : EvalStats.ratio(injectionCorrect, injectionTotal),
            priorityWithinOne: EvalStats.ratio(withinOne, answered), perCategory: scores(corpus: corpus, confusion: confusion),
            confusion: confusion,
            latency: .init(
                p50Milliseconds: EvalStats.percentile(latencies, 0.5), p95Milliseconds: EvalStats.percentile(latencies, 0.95),
                meanMilliseconds: EvalStats.mean(latencies)),
            injectionBehaviour: injection)
    }

    static func scores(corpus: [EvalEmail], confusion: [String: [String: Int]]) -> [EvalReport.CategoryScore] {
        TriageCategory.allCases.map { category in
            let name = category.rawValue
            let support = corpus.filter { $0.category == category }.count
            let truePositives = confusion[name]?[name] ?? 0
            let predicted = confusion.values.reduce(0) { $0 + ($1[name] ?? 0) }
            let precision = EvalStats.ratio(truePositives, predicted)
            let recall = EvalStats.ratio(truePositives, support)
            let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
            return .init(
                category: name, support: support, predicted: predicted, truePositives: truePositives, precision: precision,
                recall: recall, f1: f1)
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func describe(_ location: AIDataLocation) -> String {
        switch location {
        case .onDevice: return "on-device"
        case .appleCloud: return "apple-cloud"
        case .thirdParty(let vendor): return "third-party:\(vendor)"
        }
    }

    static func kind(of error: any Error) -> String {
        guard let error = error as? AIError else { return error is CancellationError ? "cancelled" : "error" }
        switch error {
        case .unavailable: return "unavailable"
        case .contextOverflow: return "contextOverflow"
        case .invalidOutput: return "invalidOutput"
        case .refused: return "refused"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .providerFailed: return "providerFailed"
        case .outputBlocked: return "outputBlocked"
        }
    }
}
