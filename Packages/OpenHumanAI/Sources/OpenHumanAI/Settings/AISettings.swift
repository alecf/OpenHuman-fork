import Foundation

public enum DraftRepliesMode: String, Sendable, Hashable, Codable, CaseIterable {
    case onDeviceAuto
    case onDemand
    case off
}

public enum OutputLanguage: Sendable, Hashable, Codable {
    case matchEmail
    case fixed(String)
}

public struct ProviderConsent: Sendable, Hashable, Codable {
    public var grantedAt: Date
    public var fingerprint: String?

    public init(grantedAt: Date, fingerprint: String?) {
        self.grantedAt = grantedAt
        self.fingerprint = fingerprint
    }
}

public struct AgentCLISettings: Sendable, Hashable, Codable {
    public var binaryPathOverride: String?
    public var model: String?
    public var inputCapTokens: Int
    public var timeoutSeconds: [AIFeature: Int]

    public init(binaryPathOverride: String? = nil, model: String? = nil,
                inputCapTokens: Int = AIPolicy.agentCLIDefaultInputCap, timeoutSeconds: [AIFeature: Int] = [:])
    {
        self.binaryPathOverride = binaryPathOverride
        self.model = model
        self.inputCapTokens = inputCapTokens
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey { case binaryPathOverride, model, inputCapTokens, timeoutSeconds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binaryPathOverride = try c.decodeIfPresent(String.self, forKey: .binaryPathOverride)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        inputCapTokens = try c.decodeIfPresent(Int.self, forKey: .inputCapTokens) ?? AIPolicy.agentCLIDefaultInputCap
        timeoutSeconds = try c.decodeIfPresent([AIFeature: Int].self, forKey: .timeoutSeconds) ?? [:]
    }
}

public struct AISettings: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var draftReplies: DraftRepliesMode
    public var agentCLIAutoQuickReplies: Bool
    public var providerOrder: [AIProviderID]
    public var pccEnabled: Bool
    public var featurePins: [AIFeature: AIProviderID]
    public var backgroundTriage: Bool
    public var autoSummarizeOnOpen: Bool
    public var onDeviceOnlyAccounts: Set<String>
    public var consents: [AIProviderID: ProviderConsent]
    public var agentCLI: [AIProviderID: AgentCLISettings]
    public var selectedLocalModel: String?
    public var outputLanguage: OutputLanguage
    public var smartSearch: SmartSearchSettings
    public var allowWritingTools: Bool
    public var instantReplyStrip: Bool
    public var prepareInAdvance: Bool
    public var autoDraftReplies: Bool
    public var writesRepliesAutomatically: Bool {
        draftReplies == .onDeviceAuto || (autoDraftReplies && draftReplies != .off)
    }
    public var aboutMe: String
    public var writingInstructions: String
    public var traces: AITraceSettings

    public var classifier: ClassifierPreference
    public var localClassifierInLowPowerMode: Bool
    public var modelsDirectory: String?

    public var userPreferencesText: String? {
        let about = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = writingInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if !about.isEmpty { lines.append("About me: " + about) }
        if !style.isEmpty { lines.append("How I write: " + style) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public init(
        enabled: Bool = true,
        draftReplies: DraftRepliesMode = .onDemand,
        agentCLIAutoQuickReplies: Bool = false,
        providerOrder: [AIProviderID] = [],
        pccEnabled: Bool = false,
        featurePins: [AIFeature: AIProviderID] = [:],
        backgroundTriage: Bool = true,
        autoSummarizeOnOpen: Bool = true,
        onDeviceOnlyAccounts: Set<String> = [],
        consents: [AIProviderID: ProviderConsent] = [:],
        agentCLI: [AIProviderID: AgentCLISettings] = [:],
        selectedLocalModel: String? = nil,
        outputLanguage: OutputLanguage = .matchEmail,
        allowWritingTools: Bool = false,
        instantReplyStrip: Bool = false,
        prepareInAdvance: Bool = true,
        autoDraftReplies: Bool = false,
        smartSearch: SmartSearchSettings = SmartSearchSettings(),
        aboutMe: String = "",
        writingInstructions: String = "",
        classifier: ClassifierPreference = .appleModel,
        localClassifierInLowPowerMode: Bool = false,
        modelsDirectory: String? = nil,
        traces: AITraceSettings = AITraceSettings()
    ) {
        self.classifier = classifier
        self.localClassifierInLowPowerMode = localClassifierInLowPowerMode
        self.modelsDirectory = modelsDirectory
        self.aboutMe = aboutMe
        self.writingInstructions = writingInstructions
        self.traces = traces
        self.smartSearch = smartSearch
        self.enabled = enabled
        self.draftReplies = draftReplies
        self.agentCLIAutoQuickReplies = agentCLIAutoQuickReplies
        self.providerOrder = providerOrder
        self.pccEnabled = pccEnabled
        self.featurePins = featurePins
        self.backgroundTriage = backgroundTriage
        self.autoSummarizeOnOpen = autoSummarizeOnOpen
        self.onDeviceOnlyAccounts = onDeviceOnlyAccounts
        self.consents = consents
        self.agentCLI = agentCLI
        self.selectedLocalModel = selectedLocalModel
        self.outputLanguage = outputLanguage
        self.allowWritingTools = allowWritingTools
        self.instantReplyStrip = instantReplyStrip
        self.prepareInAdvance = prepareInAdvance
        self.autoDraftReplies = autoDraftReplies
    }

    public func requiresOnDevice(accountKeys: [String?]) -> Bool {
        guard !onDeviceOnlyAccounts.isEmpty else { return false }
        if accountKeys.isEmpty { return true }
        return accountKeys.contains { key in key.map(onDeviceOnlyAccounts.contains) ?? true }
    }

    public func allowsWritingTools(accountKey: String?) -> Bool {
        enabled && allowWritingTools && !requiresOnDevice(accountKeys: [accountKey])
    }

    public func hasConsent(for providerID: AIProviderID, fingerprint: String?) -> Bool {
        guard let consent = consents[providerID] else { return false }
        return consent.fingerprint == fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, draftReplies, agentCLIAutoQuickReplies, providerOrder, pccEnabled, featurePins, backgroundTriage,
            autoSummarizeOnOpen, onDeviceOnlyAccounts, consents, agentCLI, selectedLocalModel, outputLanguage,
            allowWritingTools,
            instantReplyStrip, smartSearch, aboutMe, writingInstructions, prepareInAdvance, autoDraftReplies, classifier,
            localClassifierInLowPowerMode, modelsDirectory, traces
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        draftReplies = (try? c.decodeIfPresent(DraftRepliesMode.self, forKey: .draftReplies)) ?? d.draftReplies
        agentCLIAutoQuickReplies =
            (try? c.decodeIfPresent(Bool.self, forKey: .agentCLIAutoQuickReplies)) ?? d.agentCLIAutoQuickReplies
        providerOrder = (try? c.decodeIfPresent([AIProviderID].self, forKey: .providerOrder)) ?? d.providerOrder
        pccEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .pccEnabled)) ?? d.pccEnabled
        featurePins = (try? c.decodeIfPresent([AIFeature: AIProviderID].self, forKey: .featurePins)) ?? d.featurePins
        backgroundTriage = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundTriage)) ?? d.backgroundTriage
        autoSummarizeOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .autoSummarizeOnOpen)) ?? d.autoSummarizeOnOpen
        onDeviceOnlyAccounts =
            (try? c.decodeIfPresent(Set<String>.self, forKey: .onDeviceOnlyAccounts)) ?? d.onDeviceOnlyAccounts
        consents = (try? c.decodeIfPresent([AIProviderID: ProviderConsent].self, forKey: .consents)) ?? d.consents
        agentCLI = (try? c.decodeIfPresent([AIProviderID: AgentCLISettings].self, forKey: .agentCLI)) ?? d.agentCLI
        selectedLocalModel = (try? c.decodeIfPresent(String.self, forKey: .selectedLocalModel)) ?? d.selectedLocalModel
        outputLanguage = (try? c.decodeIfPresent(OutputLanguage.self, forKey: .outputLanguage)) ?? d.outputLanguage
        allowWritingTools = (try? c.decodeIfPresent(Bool.self, forKey: .allowWritingTools)) ?? d.allowWritingTools
        instantReplyStrip = (try? c.decodeIfPresent(Bool.self, forKey: .instantReplyStrip)) ?? d.instantReplyStrip
        prepareInAdvance = (try? c.decodeIfPresent(Bool.self, forKey: .prepareInAdvance)) ?? d.prepareInAdvance
        autoDraftReplies = (try? c.decodeIfPresent(Bool.self, forKey: .autoDraftReplies)) ?? d.autoDraftReplies
        smartSearch = (try? c.decodeIfPresent(SmartSearchSettings.self, forKey: .smartSearch)) ?? d.smartSearch
        classifier = (try? c.decodeIfPresent(ClassifierPreference.self, forKey: .classifier)) ?? d.classifier
        if classifier == .localModel, selectedLocalModel == nil {
            selectedLocalModel = AIModelDefaults.localModelBeforeChoicesWereRecorded
        }
        localClassifierInLowPowerMode = (try? c.decodeIfPresent(Bool.self, forKey: .localClassifierInLowPowerMode))
            ?? d.localClassifierInLowPowerMode
        modelsDirectory = (try? c.decodeIfPresent(String.self, forKey: .modelsDirectory)) ?? d.modelsDirectory
        aboutMe = (try? c.decodeIfPresent(String.self, forKey: .aboutMe)) ?? d.aboutMe
        writingInstructions = (try? c.decodeIfPresent(String.self, forKey: .writingInstructions)) ?? d.writingInstructions
        traces = (try? c.decodeIfPresent(AITraceSettings.self, forKey: .traces)) ?? d.traces
    }

    public mutating func useClassifier(_ id: AIProviderID) {
        featurePins[.classify] = nil
        selectedLocalModel = id.localModelID
        classifier = selectedLocalModel == nil ? .appleModel : .localModel
    }

    public func retiringLocalModels(_ retired: Set<String> = AIModelDefaults.retiredLocalModels) -> AISettings {
        func isRetired(_ id: AIProviderID) -> Bool { id.localModelID.map { retired.contains($0) } ?? false }
        var next = self
        if let model = selectedLocalModel, retired.contains(model) {
            next.selectedLocalModel = nil
            next.classifier = .appleModel
        }
        next.featurePins = featurePins.filter { !isRetired($0.value) }
        next.providerOrder = providerOrder.filter { !isRetired($0) }
        next.consents = consents.filter { !isRetired($0.key) }
        return next
    }
}

public struct SmartSearchSettings: Sendable, Hashable, Codable {
    public var enabled: Bool?
    public var providerID: AIProviderID?
    public var understandSentences: Bool

    public init(enabled: Bool? = nil, providerID: AIProviderID? = nil, understandSentences: Bool = true) {
        self.enabled = enabled
        self.providerID = providerID
        self.understandSentences = understandSentences
    }

    public func indexingEnabled(defaultProviderNeedsDownload: Bool) -> Bool {
        if let enabled { return enabled }
        return EmbeddingProviders.evalChosenDefault != nil && !defaultProviderNeedsDownload
    }

    private enum CodingKeys: String, CodingKey { case enabled, providerID, understandSentences }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SmartSearchSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        providerID = (try? c.decodeIfPresent(AIProviderID.self, forKey: .providerID)) ?? d.providerID
        understandSentences = (try? c.decodeIfPresent(Bool.self, forKey: .understandSentences)) ?? d.understandSentences
    }
}
