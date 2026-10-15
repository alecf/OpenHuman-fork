import Foundation

public enum AIModelDefaults {
    public static let pins: [AIFeature: AIProviderID] = [
        .summarize: .appleSystem,
        .replyOptions: .appleSystem,
        .rewrite: .appleSystem,
        .askInbox: .appleSystem,
        .searchPlan: .appleSystem,
        .followUp: .appleSystem,
        .scheduling: .appleSystem,
    ]

    public static func model(for feature: AIFeature, among candidates: [ProviderCandidate]) -> AIProviderID? {
        guard let pinned = pins[feature] else { return nil }
        let onDevice = candidates.filter { $0.kind == .languageModel && $0.dataLocation == .onDevice && $0.autoSelectable }
        if onDevice.contains(where: { $0.id == pinned }) { return pinned }
        // Builds without Apple's model (fake data, tests) stand in their own on-device model.
        return onDevice.first?.id
    }
}

public struct FeatureRoute: Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case yourChoice
        case mailDefault
        case firstReady
    }

    public var feature: AIFeature
    public var workload: AIWorkload
    public var choice: AIProviderID?
    public var defaultModel: AIProviderID?
    public var origin: Origin
    public var selection: ProviderSelection

    public init(feature: AIFeature, workload: AIWorkload, choice: AIProviderID?, defaultModel: AIProviderID?,
                origin: Origin, selection: ProviderSelection)
    {
        self.feature = feature
        self.workload = workload
        self.choice = choice
        self.defaultModel = defaultModel
        self.origin = origin
        self.selection = selection
    }

    public var onDeviceOnlyFeature: Bool {
        feature == .searchPlan || feature == .followUp || feature == .scheduling || workload == .background
    }

    public static func explain(
        feature: AIFeature, workload: AIWorkload, accountKeys: [String?], candidates: [ProviderCandidate],
        settings: AISettings
    ) -> FeatureRoute {
        let defaultModel = AIModelDefaults.model(for: feature, among: candidates)
        let pin = settings.featurePins[feature]
        let origin: Origin = pin != nil ? .yourChoice : (defaultModel != nil ? .mailDefault : .firstReady)
        let choice = pin ?? defaultModel
        let selection = select(feature: feature, workload: workload, accountKeys: accountKeys, candidates: candidates,
                               settings: settings, choice: choice, pinned: pin != nil)
        return FeatureRoute(feature: feature, workload: workload, choice: choice, defaultModel: defaultModel,
                            origin: origin, selection: selection)
    }

    private static func select(
        feature: AIFeature, workload: AIWorkload, accountKeys: [String?], candidates: [ProviderCandidate],
        settings: AISettings, choice: AIProviderID?, pinned: Bool
    ) -> ProviderSelection {
        if let gate = ProviderSelectionPolicy.featureGate(feature, workload: workload, settings: settings) {
            return .unavailable(gate, providerID: nil)
        }
        let onDeviceOnly = settings.requiresOnDevice(accountKeys: accountKeys)

        if let choice {
            guard let chosen = candidates.first(where: { $0.id == choice }) else {
                return .unavailable(.other("The provider chosen for this feature is not set up"), providerID: choice)
            }
            if let reason = ProviderSelectionPolicy.restriction(
                for: chosen, feature: feature, workload: workload, onDeviceOnly: onDeviceOnly, settings: settings,
                pinned: pinned)
            {
                return .unavailable(reason, providerID: choice)
            }
            if let reason = chosen.availability.unavailableReason { return .unavailable(reason, providerID: choice) }
            return .selected(chosen)
        }

        var firstUnavailable: (AIAvailability.UnavailableReason, AIProviderID)?
        var firstRestricted: (AIAvailability.UnavailableReason, AIProviderID)?
        for candidate in candidates {
            if let reason = ProviderSelectionPolicy.restriction(
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
