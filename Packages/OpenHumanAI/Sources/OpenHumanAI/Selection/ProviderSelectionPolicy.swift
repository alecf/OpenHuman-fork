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
        if let gate = featureGate(feature, workload: workload, settings: settings) {
            return .unavailable(gate, providerID: nil)
        }
        let onDeviceOnly = settings.requiresOnDevice(accountKeys: accountKeys)

        if let pinnedID = settings.featurePins[feature] {
            guard let pinned = candidates.first(where: { $0.id == pinnedID }) else {
                return .unavailable(.other("The provider chosen for this feature is not set up"), providerID: pinnedID)
            }
            if let reason = restriction(
                for: pinned, feature: feature, workload: workload, onDeviceOnly: onDeviceOnly, settings: settings,
                pinned: true)
            {
                return .unavailable(reason, providerID: pinnedID)
            }
            if let reason = pinned.availability.unavailableReason { return .unavailable(reason, providerID: pinnedID) }
            return .selected(pinned)
        }

        var firstUnavailable: (AIAvailability.UnavailableReason, AIProviderID)?
        var firstRestricted: (AIAvailability.UnavailableReason, AIProviderID)?
        for candidate in candidates {
            if let reason = restriction(
                for: candidate, feature: feature, workload: workload, onDeviceOnly: onDeviceOnly, settings: settings,
                pinned: false)
            {
                if firstRestricted == nil, candidate.autoSelectable { firstRestricted = (reason, candidate.id) }
                continue
            }
            if let reason = candidate.availability.unavailableReason {
                if firstUnavailable == nil { firstUnavailable = (reason, candidate.id) }
                continue
            }
            return .selected(candidate)
        }
        if let (reason, id) = firstUnavailable ?? firstRestricted { return .unavailable(reason, providerID: id) }
        return .unavailable(.other("No AI provider is set up"), providerID: nil)
    }
}
