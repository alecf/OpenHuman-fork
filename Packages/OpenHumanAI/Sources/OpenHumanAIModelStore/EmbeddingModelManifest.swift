import Foundation

public struct EmbeddingModelManifest: Codable, Sendable, Hashable {
    public enum Pooling: String, Codable, Sendable, Hashable {
        case cls
        case mean
        case none
    }

    public struct Tokenizer: Codable, Sendable, Hashable {
        public var kind: String
        public var vocabFile: String
        public var lowercase: Bool
        public var stripAccents: Bool
        public var unknownToken: String
        public var classToken: String
        public var separatorToken: String
        public var paddingToken: String

        public init(kind: String = "wordpiece", vocabFile: String, lowercase: Bool = true, stripAccents: Bool = true,
                    unknownToken: String = "[UNK]", classToken: String = "[CLS]", separatorToken: String = "[SEP]",
                    paddingToken: String = "[PAD]") {
            self.kind = kind
            self.vocabFile = vocabFile
            self.lowercase = lowercase
            self.stripAccents = stripAccents
            self.unknownToken = unknownToken
            self.classToken = classToken
            self.separatorToken = separatorToken
            self.paddingToken = paddingToken
        }
    }

    public struct Inputs: Codable, Sendable, Hashable {
        public var inputIDs: String
        public var attentionMask: String?
        public var tokenTypeIDs: String?

        public init(inputIDs: String = "input_ids", attentionMask: String? = "attention_mask", tokenTypeIDs: String? = nil) {
            self.inputIDs = inputIDs
            self.attentionMask = attentionMask
            self.tokenTypeIDs = tokenTypeIDs
        }
    }

    public var model: ModelManifest
    public var modelFile: String
    public var tokenizer: Tokenizer
    public var inputs: Inputs
    public var output: String
    public var pooling: Pooling
    public var maxSequenceLength: Int
    public var fixedSequenceLength: Int?
    public var dimension: Int?
    public var queryPrefix: String
    public var documentPrefix: String

    public init(model: ModelManifest, modelFile: String, tokenizer: Tokenizer, inputs: Inputs = Inputs(),
                output: String, pooling: Pooling, maxSequenceLength: Int, fixedSequenceLength: Int? = nil,
                dimension: Int? = nil, queryPrefix: String = "", documentPrefix: String = "") {
        self.model = model
        self.modelFile = modelFile
        self.tokenizer = tokenizer
        self.inputs = inputs
        self.output = output
        self.pooling = pooling
        self.maxSequenceLength = maxSequenceLength
        self.fixedSequenceLength = fixedSequenceLength
        self.dimension = dimension
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
    }

    public func validate() throws {
        try model.validate()
        func fail(_ message: String) -> ModelStoreError { .invalidManifest(message) }
        guard model.format == .coreml else { throw fail("embedding models are Core ML models") }
        let paths = model.files.map(\.path)
        guard paths.contains(where: { $0 == modelFile || $0.hasPrefix(modelFile + "/") }) else {
            throw fail("the model file is not among the files")
        }
        guard paths.contains(tokenizer.vocabFile) else { throw fail("the vocabulary is not among the files") }
        guard tokenizer.kind == "wordpiece" else { throw fail("unsupported tokenizer") }
        guard (8...8_192).contains(maxSequenceLength) else { throw fail("bad sequence length") }
        if let fixedSequenceLength, !(2...maxSequenceLength).contains(fixedSequenceLength) {
            throw fail("bad fixed sequence length")
        }
        if let dimension, !(8...8_192).contains(dimension) { throw fail("bad dimension") }
        guard queryPrefix.count <= 200, documentPrefix.count <= 200 else { throw fail("prefix too long") }
    }
}
