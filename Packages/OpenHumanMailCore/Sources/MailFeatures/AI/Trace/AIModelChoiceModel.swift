import Foundation
import Observation
import OpenHumanAI

extension AICenter {
    public func route(for feature: AIFeature, accountKeys: [String?]) async -> (FeatureRoute, [ProviderCandidate])? {
        await route(for: feature, accountKeys: accountKeys, settings: settings)
    }

    func route(for feature: AIFeature, accountKeys: [String?], settings: AISettings,
               workload: AIWorkload? = nil) async -> (FeatureRoute, [ProviderCandidate])? {
        guard let registry else { return nil }
        let candidates = await registry.candidates(for: feature, settings: settings)
        let explained = FeatureRoute.explain(
            feature: feature, workload: workload ?? ProviderSelectionPolicy.workload(for: feature, trigger: .user),
            accountKeys: accountKeys, candidates: candidates, settings: settings)
        return (explained, candidates)
    }

    public func whyLine(for feature: AIFeature, accountKeys: [String?]) async -> String? {
        guard let found = await route(for: feature, accountKeys: accountKeys) else { return nil }
        let (explained, candidates) = found
        return AITraceWording.why(explained, name: Self.namer(candidates))
    }

    public func whyLine(for trace: AITraceRecord) async -> String? {
        let accounts: [String?] = trace.accountKeys.isEmpty ? [nil] : trace.accountKeys.map { Optional($0) }
        guard let found = await route(for: trace.feature, accountKeys: accounts) else { return nil }
        let (explained, candidates) = found
        let name = Self.namer(candidates)
        let now = AITraceWording.traceWhy(explained, name: name)
        guard let current = explained.selection.candidate?.id, current != trace.providerID else { return now }
        return String(localized: "This feature now uses \(name(current)).") + " " + now
    }

    static func namer(_ candidates: [ProviderCandidate]) -> (AIProviderID) -> String {
        { id in AITraceWording.modelName(id, displayName: candidates.first { $0.id == id }?.displayName ?? id.rawValue) }
    }

    static let offeredOffDevice: [AIProviderID] = [.agentClaude, .agentCodex]

    func offeredModels(besides registered: [ProviderCandidate]) async -> [ProviderCandidate] {
        var offered: [ProviderCandidate] = []
        for id in Self.offeredOffDevice where !id.isExperimental && !registered.contains(where: { $0.id == id }) {
            guard let provider = makeProvider(id) else { continue }
            offered.append(ProviderCandidate(
                id: id, displayName: provider.displayName, dataLocation: await provider.capabilities().dataLocation,
                availability: .available, consented: false, autoSelectable: true))
        }
        return offered
    }

    func classifierCandidates() async -> [ProviderCandidate] {
        guard let registry else { return [] }
        var found: [ProviderCandidate] = []
        for classifier in registry.classifiers where classifier.dataLocation == .onDevice {
            found.append(ProviderCandidate(
                id: classifier.id, displayName: classifier.displayName, kind: .classifier,
                dataLocation: classifier.dataLocation, availability: await classifier.availability(), consented: true,
                autoSelectable: !classifier.id.isExperimental))
        }
        return found.filter { !$0.id.isLocalModel } + found.filter(\.id.isLocalModel)
    }
}

@MainActor @Observable
public final class AIModelChoiceModel {
    public struct Option: Identifiable, Hashable, Sendable {
        public let id: AIProviderID
        public let name: String
        public let status: String?
        public let isDefault: Bool
        public let isEnabled: Bool
        public let badge: AIProviderBadge
    }

    public let feature: AIFeature
    public let accountKey: String?
    public private(set) var options: [Option] = []
    public private(set) var chosen: AIProviderID?
    public private(set) var why = ""
    public private(set) var note: String?
    public private(set) var error: String?
    @ObservationIgnored public var onChange: (@MainActor () async -> Void)?
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

    public var isSettingsWide: Bool { accountKey == nil }

    public var isFixed: Bool { options.count <= 1 }

    public var chosenName: String? { options.first { $0.id == chosen }?.name }

    public var onlyChoiceText: String? {
        guard isFixed, let only = options.first else { return nil }
        return String(localized: "\(only.name) is the only model Mail can use for this.")
    }

    public static let futureRewrites = String(localized: "Used for every ⌘J in a draft from now on, not just this answer. Also in Settings › AI.")

    public func refresh() async {
        var settings = center.settings
        if isSettingsWide { settings.onDeviceOnlyAccounts = [] }
        guard let found = await center.route(for: feature, accountKeys: [accountKey], settings: settings) else {
            options = []
            chosen = nil
            why = ""
            note = nil
            return
        }
        let (route, registered) = found
        var candidates: [ProviderCandidate]
        if feature == .classify {
            candidates = await center.classifierCandidates()
        } else {
            candidates = registered.filter { $0.kind == .languageModel }
            candidates += await center.offeredModels(besides: candidates)
        }
        defaultModel = feature == .classify ? AIModelDefaults.model(for: .classify, among: candidates) : route.defaultModel
        chosen = route.choice
        let name = AICenter.namer(candidates)
        why = AITraceWording.why(route, name: name)
        options = Self.options(feature: feature, choice: route.choice, defaultModel: defaultModel, candidates: candidates,
                               onDeviceOnlyAccount: !isSettingsWide && center.settings.requiresOnDevice(accountKeys: [accountKey]),
                               settings: center.settings, name: name)
        note = Self.note(feature: feature, chosen: candidates.first { $0.id == route.choice }, settings: center.settings,
                         settingsWide: isSettingsWide)
    }

    public func choose(_ id: AIProviderID) async {
        guard let option = options.first(where: { $0.id == id }), option.isEnabled else { return }
        let feature = feature
        let pin: AIProviderID? = id == defaultModel ? nil : id
        do {
            try center.update { settings in
                if feature == .classify {
                    settings.featurePins[.classify] = nil
                    settings.classifier = id.isLocalModel ? .localModel : .appleModel
                } else {
                    settings.featurePins[feature] = pin
                    if feature == .replyOptions { settings.agentCLIAutoQuickReplies = id.isAgentCLI }
                }
            }
            error = nil
        } catch {
            self.error = AIActivityModel.saveFailure
        }
        await onChange?()
        await refresh()
    }

    nonisolated static func options(
        feature: AIFeature, choice: AIProviderID?, defaultModel: AIProviderID?, candidates: [ProviderCandidate],
        onDeviceOnlyAccount: Bool, settings: AISettings, name: (AIProviderID) -> String
    ) -> [Option] {
        let kind: ProviderCandidate.Kind = feature == .classify ? .classifier : .languageModel
        let usable = candidates.filter { $0.kind == kind }
        let ordered = usable.filter { !$0.dataLocation.leavesDevice } + usable.filter(\.dataLocation.leavesDevice)
        return ordered.map { candidate in
            let chosen = candidate.id == choice
            let blocked = blockedReason(candidate, feature: feature, onDeviceOnlyAccount: onDeviceOnlyAccount,
                                        settings: settings)
            let status = blocked ?? candidate.availability.unavailableReason.flatMap(shortReason)
            return Option(id: candidate.id, name: name(candidate.id), status: status,
                          isDefault: candidate.id == defaultModel, isEnabled: chosen || blocked == nil,
                          badge: AIProviderBadge(providerName: candidate.displayName, location: candidate.dataLocation))
        }
    }

    nonisolated static func blockedReason(_ candidate: ProviderCandidate, feature: AIFeature, onDeviceOnlyAccount: Bool,
                                          settings: AISettings) -> String? {
        if candidate.dataLocation.leavesDevice {
            let staysOnMac = feature == .classify || feature == .searchPlan || feature == .followUp || feature == .scheduling
            if staysOnMac { return String(localized: "runs on this Mac only") }
            if onDeviceOnlyAccount { return String(localized: "this account allows AI on this Mac only") }
            if candidate.dataLocation == .appleCloud, !settings.pccEnabled { return String(localized: "turned off") }
            if !candidate.consented { return String(localized: "needs your OK") }
        }
        switch candidate.availability.unavailableReason {
        case .binaryNotFound?: return String(localized: "not installed")
        case .modelNotDownloaded?, .downloading?: return String(localized: "not downloaded")
        case .deviceNotEligible?: return String(localized: "this Mac can't run it")
        case .entitlementMissing?: return String(localized: "not in this version of Mail")
        default: return nil
        }
    }

    nonisolated static func shortReason(_ reason: AIAvailability.UnavailableReason) -> String? {
        switch reason {
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is off")
        case .modelNotReady: String(localized: "still getting ready")
        case .notLoggedIn: String(localized: "not signed in")
        case .unsupportedVersion: String(localized: "needs an update")
        case .localeNotSupported: String(localized: "doesn't support this language")
        case .usageLimitReached: String(localized: "limit reached")
        case .notConsented: String(localized: "needs your OK")
        case .onDeviceOnly: String(localized: "this account allows AI on this Mac only")
        case .binaryNotFound: String(localized: "not installed")
        case .modelNotDownloaded, .downloading: String(localized: "not downloaded")
        case .deviceNotEligible: String(localized: "this Mac can't run it")
        case .entitlementMissing: String(localized: "not in this version of Mail")
        case .disabledBySettings: nil
        case .other(let text): text
        }
    }

    nonisolated static func note(feature: AIFeature, chosen: ProviderCandidate?, settings: AISettings,
                                 settingsWide: Bool) -> String? {
        guard let chosen, chosen.dataLocation.leavesDevice else { return nil }
        var lines: [String] = []
        if feature == .replyOptions, settings.draftReplies == .onDeviceAuto, case .thirdParty(let vendor) = chosen.dataLocation {
            lines.append(String(localized: "Each conversation you open is sent to \(vendor) for quick replies."))
        }
        if settingsWide, !settings.onDeviceOnlyAccounts.isEmpty {
            lines.append(String(localized: "Accounts set to On-device AI only can't use it; Mail says so there and doesn't use another model."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

public struct AIBackgroundModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let model: String
    public let detail: String
}

extension AICenter {
    static let backgroundFeatures: [(id: String, feature: AIFeature, title: String)] = [
        ("summarize.line", .summarize, String(localized: "One-line summaries")),
        ("searchPlan", .searchPlan, AITraceWording.feature(.searchPlan)),
        ("followUp", .followUp, String(localized: "Follow-up checks")),
        ("scheduling", .scheduling, AITraceWording.feature(.scheduling)),
    ]

    public func backgroundModels() async -> [AIBackgroundModel] {
        var rows: [AIBackgroundModel] = []
        for entry in Self.backgroundFeatures {
            var settings = self.settings
            settings.onDeviceOnlyAccounts = []
            guard let found = await route(for: entry.feature, accountKeys: [nil], settings: settings,
                                          workload: .background) else { continue }
            let (route, candidates) = found
            let name = Self.namer(candidates)
            rows.append(AIBackgroundModel(id: entry.id, title: entry.title, model: route.choice.map(name) ?? "—",
                                          detail: Self.backgroundWhy(route, name: name)))
        }
        return rows
    }

    nonisolated static func backgroundWhy(_ route: FeatureRoute, name: (AIProviderID) -> String) -> String {
        switch route.selection {
        case .unavailable(.onDeviceOnly, _) where route.feature == .summarize:
            return String(localized: "Off: they run in the background, which stays on this Mac, and Conversation summary uses a model off it.")
        case .selected where route.origin == .yourChoice && route.feature == .summarize:
            return String(localized: "Same as Conversation summary · in the background, on this Mac")
        case .selected where route.origin == .yourChoice:
            return String(localized: "Your choice · in the background, on this Mac")
        case .selected:
            return String(localized: "Mail's default · in the background, on this Mac")
        case .unavailable(let reason, let id):
            return AIWording.reason(reason, providerName: id.map(name))
        }
    }
}
