import Foundation

public enum AIDataLocation: Sendable, Hashable, Codable {
    case onDevice
    case appleCloud
    case thirdParty(vendor: String)

    public var leavesDevice: Bool { self != .onDevice }
}

public enum TokenCounting: Sendable, Hashable {
    case exact
    case heuristic
}

public enum StructuredOutputSupport: Sendable, Hashable {
    case native
    case promptedJSON
    case none
}

public enum LatencyClass: Sendable, Hashable {
    case interactive
    case slow
}

public struct AICapabilities: Sendable, Hashable {
    public var contextTokens: Int?
    public var policyInputCap: Int?
    public var tokenCounting: TokenCounting
    public var streaming: Bool
    public var structuredOutput: StructuredOutputSupport
    public var dataLocation: AIDataLocation
    public var typicalLatency: LatencyClass

    public var dataLeavesDevice: Bool { dataLocation != .onDevice }

    public init(
        contextTokens: Int?,
        policyInputCap: Int? = nil,
        tokenCounting: TokenCounting,
        streaming: Bool,
        structuredOutput: StructuredOutputSupport,
        dataLocation: AIDataLocation,
        typicalLatency: LatencyClass
    ) {
        self.contextTokens = contextTokens
        self.policyInputCap = policyInputCap
        self.tokenCounting = tokenCounting
        self.streaming = streaming
        self.structuredOutput = structuredOutput
        self.dataLocation = dataLocation
        self.typicalLatency = typicalLatency
    }
}
