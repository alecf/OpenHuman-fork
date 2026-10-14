import AIEvalKit
import Foundation
import OpenHumanAI
import OpenHumanAIAgentCLI
import OpenHumanAIApple
import OpenHumanAITesting

struct Options {
    var provider = "fake"
    var json = false
    var limit: Int?
}

func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--provider":
            index += 1
            guard index < arguments.count else { return nil }
            options.provider = arguments[index]
        case "--json": options.json = true
        case "--limit":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value > 0 else { return nil }
            options.limit = value
        default: return nil
        }
        index += 1
    }
    return options
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: ai-eval [--provider fake|apple|apple-tagging|apple-lm|agent.claude|agent.codex] [--json] [--limit N]\n".utf8))
    exit(2)
}

let labelled = (try? EvalCorpus.load()) ?? []

func makeClassifier(_ name: String) -> (any AIClassificationProvider)? {
    switch name {
    case "fake":
        return FakeClassifier(id: "fake.oracle", displayName: "Fake oracle classifier") { input in
            let match = labelled.first { $0.subject == input.subject.text && $0.from == input.sender.text }
            return TriageResult(category: match?.category ?? .other, priority: match?.priority ?? 0, reason: "Fake.")
        }
    case "apple": return AppleSystemClassifier()
    case "apple-tagging": return AppleSystemClassifier(useCase: .contentTagging)
    case "apple-lm":
        return ProviderClassifier(wrapping: AppleSystemProvider(source: SystemModelSource()), dataLocation: .onDevice)
    case "agent.claude":
        return ProviderClassifier(wrapping: AgentCLIProvider(kind: .claude), dataLocation: .thirdParty(vendor: "Anthropic"))
    case "agent.codex":
        return ProviderClassifier(wrapping: AgentCLIProvider(kind: .codex), dataLocation: .thirdParty(vendor: "OpenAI"))
    default: return nil
    }
}

guard let classifier = makeClassifier(options.provider) else {
    FileHandle.standardError.write(Data("unknown provider \(options.provider)\n".utf8))
    exit(2)
}
let availability = await classifier.availability()
guard availability.isAvailable else {
    FileHandle.standardError.write(Data("\(classifier.displayName) is unavailable: \(availability)\n".utf8))
    exit(3)
}

var corpus = try EvalCorpus.load()
if let limit = options.limit { corpus = Array(corpus.prefix(limit)) }
let report = await EvalRunner.run(classifier: classifier, corpus: corpus) { done, total in
    if !options.json { FileHandle.standardError.write(Data("\r\(done)/\(total)".utf8)) }
}
if options.json {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
} else {
    FileHandle.standardError.write(Data("\r".utf8))
    print(report.summary)
}
