import Foundation
import OpenHumanAI
import OpenHumanAIApple
import OpenHumanAIModelStore
import OpenHumanAITesting
import SearchEvalKit

struct Options {
    var provider = "fake"
    var storage = VectorStorage.int8
    var chunks = 1
    var tau: Float = 0
    var grid = true
    var json = false
    var perQuery = false
    var ownStore = false
    var store: String?
    var labels: String?
    var manifest: String?
    var modelDirectory: String?
}

func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    func value() -> String? {
        index += 1
        return index < arguments.count ? arguments[index] : nil
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--provider": guard let v = value() else { return nil }; options.provider = v
        case "--storage":
            switch value() ?? "" {
            case "int8": options.storage = .int8
            case "fp16": options.storage = .float16
            case "f32": options.storage = .float32
            default: return nil
            }
        case "--chunks": guard let v = value(), let n = Int(v), (1...16).contains(n) else { return nil }; options.chunks = n
        case "--tau": guard let v = value(), let t = Float(v) else { return nil }; options.tau = t
        case "--no-grid": options.grid = false
        case "--json": options.json = true
        case "--per-query": options.perQuery = true
        case "--own-store": options.ownStore = true
        case "--store": guard let v = value() else { return nil }; options.store = v
        case "--labels": guard let v = value() else { return nil }; options.labels = v
        case "--manifest": guard let v = value() else { return nil }; options.manifest = v
        case "--model-dir": guard let v = value() else { return nil }; options.modelDirectory = v
        default: return nil
        }
        index += 1
    }
    return options
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    fail("usage: search-eval [--provider fake|none|apple.nl.sentence|apple.nl.contextual|local.bge-small-en] "
        + "[--model-dir DIR --manifest FILE] [--storage int8|fp16|f32] [--chunks N] [--tau X] [--no-grid] [--json] "
        + "[--per-query] [--own-store --store DIR --labels FILE]", code: 2)
}

func makeProvider(_ options: Options) throws -> (any TextEmbeddingProvider)? {
    switch options.provider {
    case "none": return nil
    case "fake": return FakeEmbeddingProvider()
    case EmbeddingProviders.appleSentence.rawValue: return NLSentenceEmbeddingProvider()
    case EmbeddingProviders.appleContextual.rawValue: return NLContextualEmbeddingProvider()
    case EmbeddingProviders.bgeSmall.rawValue:
        guard let manifest = options.manifest, let directory = options.modelDirectory else {
            fail("local.bge-small-en needs --manifest and --model-dir (a model already on disk; nothing is downloaded)", code: 2)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        let parsed = try JSONDecoder().decode(EmbeddingModelManifest.self, from: data)
        return CoreMLEmbeddingProvider(manifest: parsed, modelDirectory: URL(fileURLWithPath: directory, isDirectory: true))
    default:
        fail("unknown provider \(options.provider)", code: 2)
    }
}

let provider: (any TextEmbeddingProvider)?
do {
    provider = try makeProvider(options)
} catch {
    fail("could not set up the provider (\(String(describing: type(of: error))))", code: 3)
}
if let provider {
    guard provider.dataLocation == .onDevice else { fail("embedding providers must run on this Mac", code: 3) }
    let availability = await provider.availability()
    guard availability.isAvailable else {
        fail("\(provider.displayName) is unavailable on this Mac: \(availability)", code: 3)
    }
}

let corpus: BuiltCorpus
let queries: [CorpusQuery]
if options.ownStore {
    guard let store = options.store, let labelsPath = options.labels else {
        fail("--own-store needs --store and --labels", code: 2)
    }
    do {
        let labels = try LabelsPathGuard.load(URL(fileURLWithPath: labelsPath))
        queries = LabelsPathGuard.queries(labels)
        corpus = try AuthorStore.load(directory: URL(fileURLWithPath: store, isDirectory: true))
    } catch let refusal as LabelsPathGuard.Refusal {
        fail("refused: \(refusal)", code: 4)
    } catch {
        fail("could not read the store or the labels (\(String(describing: type(of: error))))", code: 4)
    }
} else {
    guard options.store == nil, options.labels == nil else { fail("--store and --labels need --own-store", code: 2) }
    corpus = try BuiltCorpus.build(RetrievalCorpus.loadEmails())
    queries = try RetrievalCorpus.loadQueries()
}

let evalOptions = SearchEvalOptions(storage: options.storage, chunks: options.chunks, tau: options.tau,
                                    runGrid: options.grid, perQuery: options.perQuery)
var index: EvalVectorIndex?
if let provider {
    FileHandle.standardError.write(Data("embedding \(corpus.documents.count) messages…\n".utf8))
    index = try await EvalVectorIndex.build(corpus, provider: provider, storage: options.storage, chunks: options.chunks)
}
let report = try await SearchEvalRunner.run(corpus: corpus, queries: queries, provider: provider, index: index,
                                            options: evalOptions) { done, total in
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
if options.ownStore {
    let categories = try AuthorStore.categoryQueries(corpus)
    let precision = try await SearchEvalRunner.categoryPrecision(corpus: corpus, categories: categories,
                                                                 provider: provider, index: index, options: evalOptions)
    for row in precision {
        print("category queries (\(categories.count)): \(row.arm.rawValue) precision@20 \(String(format: "%.3f", row.precision))")
    }
}
