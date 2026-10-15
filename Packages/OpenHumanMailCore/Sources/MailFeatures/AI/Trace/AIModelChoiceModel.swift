import Foundation
import Observation
import OpenHumanAI

extension AICenter {
    public func route(for feature: AIFeature, accountKeys: [String?]) async -> (FeatureRoute, [ProviderCandidate])? {
        guard let registry else { return nil }
        let settings = self.settings
        let candidates = await registry.candidates(for: feature, settings: settings)
        let workload = ProviderSelectionPolicy.workload(for: feature, trigger: .user)
        let explained = FeatureRoute.explain(feature: feature, workload: workload, accountKeys: accountKeys,
                                             candidates: candidates, settings: settings)
        return (explained, candidates)
    }

    public func whyLine(for feature: AIFeature, accountKeys: [String?]) async -> String? {
        guard let found = await route(for: feature, accountKeys: accountKeys) else { return nil }
        let (explained, candidates) = found
        return AITraceWording.why(explained) { id in
            AITraceWording.modelName(id, displayName: candidates.first { $0.id == id }?.displayName ?? id.rawValue)
        }
    }

    public func whyLine(for trace: AITraceRecord) async -> String? {
        let accounts: [String?] = trace.accountKeys.isEmpty ? [nil] : trace.accountKeys.map { Optional($0) }
        guard let found = await route(for: trace.feature, accountKeys: accounts) else { return nil }
        let (explained, candidates) = found
        let name = { (id: AIProviderID) in
            AITraceWording.modelName(id, displayName: candidates.first { $0.id == id }?.displayName ?? id.rawValue)
        }
        let now = AITraceWording.why(explained, name: name)
        guard let current = explained.selection.candidate?.id, current != trace.providerID else { return now }
        return String(localized: "This feature now uses \(name(current)).") + " " + now
    }
}

@MainActor @Observable
public final class AIModelChoiceModel {
    public struct Option: Identifiable, Hashable, Sendable {
        public let id: AIProviderID
        public let name: String
        public let status: String?
        public let isDefault: Bool
        public let badge: AIProviderBadge
    }

    public let feature: AIFeature
    public let accountKey: String?
    public private(set) var options: [Option] = []
    public private(set) var chosen: AIProviderID?
    public private(set) var why = ""
    public private(set) var error: String?
    @ObservationIgnored private var defaultModel: AIProviderID?
    @ObservationIgnored private let center: AICenter

    public init(center: AICenter, feature: AIFeature, accountKey: String?) {
        self.center = center
        self.feature = feature
        self.accountKey = accountKey
    }

    public var title: String {
        String(localized: "Model for \(AITraceWording.feature(feature))")
    }

    public func refresh() async {
        guard let found = await center.route(for: feature, accountKeys: [accountKey]) else {
            options = []
            chosen = nil
            why = ""
            return
        }
        let (route, candidates) = found
        defaultModel = route.defaultModel
        chosen = route.choice
        let name = { (id: AIProviderID) in
            AITraceWording.modelName(id, displayName: candidates.first { $0.id == id }?.displayName ?? id.rawValue)
        }
        why = AITraceWording.why(route, name: name)
        options = candidates
            .filter { $0.kind == .languageModel && (($0.dataLocation == .onDevice && $0.autoSelectable) || $0.id == route.choice) }
            .map { candidate in
                Option(id: candidate.id, name: name(candidate.id),
                       status: candidate.availability.unavailableReason.map {
                           AIWording.reason($0, providerName: candidate.displayName)
                       },
                       isDefault: candidate.id == route.defaultModel,
                       badge: AIProviderBadge(providerName: candidate.displayName, location: candidate.dataLocation))
            }
    }

    public func choose(_ id: AIProviderID) async {
        let feature = feature
        let pin: AIProviderID? = id == defaultModel ? nil : id
        do {
            try center.update { $0.featurePins[feature] = pin }
            error = nil
        } catch {
            self.error = AIActivityModel.saveFailure
        }
        await refresh()
    }
}
