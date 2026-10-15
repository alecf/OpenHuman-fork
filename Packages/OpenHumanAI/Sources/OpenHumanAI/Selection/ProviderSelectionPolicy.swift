import Foundation

public enum AIWorkload: String, Sendable, Hashable, Codable, CaseIterable {
    case background
    case interactive
    case autoQuickReplies
}

public struct ProviderCandidate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case languageModel
        case classifier
    }

    public var id: AIProviderID
    public var displayName: String
    public var kind: Kind
    public var dataLocation: AIDataLocation
    public var availability: AIAvailability
    public var consented: Bool
    public var autoSelectable: Bool

    public init(id: AIProviderID, displayName: String, kind: Kind = .languageModel, dataLocation: AIDataLocation,
                availability: AIAvailability, consented: Bool, autoSelectable: Bool)
    {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.dataLocation = dataLocation
        self.availability = availability
        self.consented = consented
        self.autoSelectable = autoSelectable
    }
}

public enum ProviderSelection: Sendable, Hashable {
    case selected(ProviderCandidate)
    case unavailable(AIAvailability.UnavailableReason, providerID: AIProviderID?)

    public var candidate: ProviderCandidate? {
        if case .selected(let candidate) = self { return candidate }
        return nil
    }
}

public enum ProviderSelectionPolicy {
    public static func workload(for feature: AIFeature, trigger: AITrigger) -> AIWorkload {
        switch (feature, trigger) {
        case (.classify, _): return .background
        case (.searchPlan, _): return .background
        case (.followUp, _): return .background
        case (.scheduling, _): return .background
        case (.summarize, .automatic): return .background
        case (.replyOptions, .automatic): return .autoQuickReplies
        default: return .interactive
        }
    }

    public static func featureGate(_ feature: AIFeature, workload: AIWorkload, settings: AISettings)
        -> AIAvailability.UnavailableReason?
    {
        if !settings.enabled { return .disabledBySettings }
        switch feature {
        case .classify:
            if !settings.backgroundTriage { return .disabledBySettings }
        case .summarize:
            if workload == .background, !settings.autoSummarizeOnOpen { return .disabledBySettings }
        case .replyOptions:
            if settings.draftReplies == .off { return .disabledBySettings }
            if workload == .autoQuickReplies, !settings.writesRepliesAutomatically { return .disabledBySettings }
        case .rewrite, .askInbox:
            break
        case .searchPlan:
            if !settings.smartSearch.understandSentences { return .disabledBySettings }
        case .followUp:
            break
        case .scheduling:
            break
        }
        return nil
    }

    public static func restriction(
        for candidate: ProviderCandidate, feature: AIFeature, workload: AIWorkload, onDeviceOnly: Bool,
        settings: AISettings, pinned: Bool
    ) -> AIAvailability.UnavailableReason? {
        if candidate.kind == .classifier, feature != .classify { return .other("not a language model") }
        if feature == .searchPlan, candidate.dataLocation != .onDevice { return .onDeviceOnly }
        if feature == .followUp, candidate.dataLocation != .onDevice { return .onDeviceOnly }
        if feature == .scheduling, candidate.dataLocation != .onDevice { return .onDeviceOnly }
        if !candidate.autoSelectable, !pinned { return .disabledBySettings }
        let location = candidate.dataLocation
        if location == .onDevice { return nil }
        if workload == .background || onDeviceOnly { return .onDeviceOnly }
        if feature == .askInbox, !pinned { return .onDeviceOnly }
        switch location {
        case .onDevice:
            return nil
        case .appleCloud:
            if workload != .interactive { return .onDeviceOnly }
            if !settings.pccEnabled { return .disabledBySettings }
        case .thirdParty:
            if workload == .autoQuickReplies, !settings.agentCLIAutoQuickReplies || settings.draftReplies != .onDeviceAuto {
                return .onDeviceOnly
            }
        }
        if !candidate.consented { return .notConsented }
        return nil
    }

    public static func select(
        feature: AIFeature, workload: AIWorkload, accountKeys: [String?], candidates: [ProviderCandidate],
        settings: AISettings
    ) -> ProviderSelection {
        FeatureRoute.explain(feature: feature, workload: workload, accountKeys: accountKeys, candidates: candidates,
                             settings: settings).selection
    }
}
