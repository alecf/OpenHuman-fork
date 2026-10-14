import Foundation

public enum AITask: String, Sendable, Hashable, Codable, CaseIterable {
    case summarize, replyOptions, rewrite, classify, askInbox, summarizeChunk, reduce
    case searchPlan
    case followUp
    case scheduling
}

public struct PromptID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let name: String
    public let version: Int

    public init(_ name: String, version: Int) {
        self.name = name
        self.version = version
    }

    public init?(_ string: String) {
        let pieces = string.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, let version = Int(pieces[1]), version > 0 else { return nil }
        self.init(String(pieces[0]), version: version)
    }

    public var description: String { "\(name)@\(version)" }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = PromptID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad prompt id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct TrustedPart: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case userInstruction
        case userQuestion
        case userName
        case today
        case position
        case userPreferences
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct UntrustedPart: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case emailBody, subject, sender, excerpt
        case summary
        case draft
        case styleExample
    }

    public let kind: Kind
    public let id: String
    public let text: String
    public let date: Date?

    public init(kind: Kind, id: String, text: String, date: Date? = nil) {
        self.kind = kind
        self.id = id
        self.text = text
        self.date = date
    }
}

public enum OutputSpec: Sendable, Hashable {
    case text(maxTokens: Int)
    case json(schema: JSONSchema, maxTokens: Int)

    public var maxTokens: Int {
        switch self {
        case .text(let maxTokens), .json(_, let maxTokens): return maxTokens
        }
    }

    public var schema: JSONSchema? {
        if case .json(let schema, _) = self { return schema }
        return nil
    }
}

public struct AIRequest: Sendable {
    public var task: AITask
    public var promptID: PromptID
    public var system: String
    public var trusted: [TrustedPart]
    public var untrusted: [UntrustedPart]
    public var output: OutputSpec
    public var temperature: Double?
    public var nonce: String
    public var searchTool: AISearchToolSession?

    public init(
        task: AITask,
        promptID: PromptID,
        system: String,
        trusted: [TrustedPart],
        untrusted: [UntrustedPart],
        output: OutputSpec,
        temperature: Double? = nil,
        nonce: String,
        searchTool: AISearchToolSession? = nil
    ) {
        self.task = task
        self.promptID = promptID
        self.system = system
        self.trusted = trusted
        self.untrusted = untrusted
        self.output = output
        self.temperature = temperature
        self.nonce = nonce
        self.searchTool = searchTool
    }

    public func renderedInput() -> String {
        let trustedBlock = Untrusted.renderTrusted(trusted, nonce: nonce)
        let dataBlock = Untrusted.render(untrusted, nonce: nonce)
        if trustedBlock.isEmpty { return dataBlock }
        if dataBlock.isEmpty { return trustedBlock }
        return trustedBlock + "\n\n" + dataBlock
    }
}

public enum AIEvent: Sendable {
    case started(providerID: AIProviderID, model: String?)
    case textDelta(String)
    case structured(Data)
    case finished(usage: AIUsage?)
}

public struct AIUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var reasoningTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
    }
}
