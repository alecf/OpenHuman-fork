import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

@MainActor
@Observable
public final class AutoLabelSettingsModel {
    public enum Placement: String, CaseIterable, Sendable, Hashable {
        case leave, important, other

        public var title: String {
            switch self {
            case .leave: String(localized: "Leave as is")
            case .important: String(localized: "Important")
            case .other: String(localized: "Other")
            }
        }
    }

    public let enabled: StoredSetting<Bool>
    public let applyToGmail: StoredSetting<Bool>
    public let showInGmail: StoredSetting<Bool>
    public let availability: SettingsAvailability
    public let center: AutoLabelCenter?
    public private(set) var placements: [String: Placement] = [:]
    public private(set) var errorText: String?
    public private(set) var isBusy = false

    @ObservationIgnored private let importance: (any ImportanceRulesPort)?
    @ObservationIgnored private let data: any MailDataSource

    public init(environment: AppEnvironment) {
        enabled = StoredSetting(AppSettings.autoLabelsEnabled, port: environment.settings)
        applyToGmail = StoredSetting(AppSettings.autoLabelsApplyToGmail, port: environment.settings)
        showInGmail = StoredSetting(AppSettings.autoLabelsShowInGmail, port: environment.settings)
        availability = SettingsAvailability(environment: environment)
        center = environment.autoLabels
        importance = environment.importance
        data = environment.data
    }

    public static let categories = AutoLabelCategory.allCases.map(\.title)

    public static let enabledNote = String(localized: """
        Sorts new mail in your inbox into Respond, Meeting, Invoice, Travel, Pitch, Social, News and Marketing with \
        Apple's on-device model. It runs on this Mac; no email text leaves it. Conversations where you sent the last \
        message are marked Waiting.
        """)
    public static let applyNote = String(localized: """
        Adds an “OpenHuman/<label>” label in Gmail, so your other Macs and a fresh install see the same labels. \
        Only while Mail may change your mailbox; your own labels are never touched.
        """)
    public static let showNote = String(localized: """
        New “OpenHuman/<label>” labels show in Gmail's label list and message list. Turn off to create new ones hidden. \
        Labels Gmail already has keep how they show; change those in Gmail › Settings › Labels.
        """)
    public static let classifyNote = String(localized: "Sorts the inbox's last 14 days now.")
    public static let resetNote = String(localized: """
        Takes Mail's auto labels off your conversations (Undo brings them back) and starts again with new mail. The \
        labels themselves stay in Gmail, empty.
        """)
    public static let placementNote = String(localized: """
        An importance rule for each label: “Other” keeps it out of Important, “Important” keeps it in. Your own rules \
        for a sender, domain, Gmail label or word always win.
        """)

    public func start() {
        enabled.start()
        applyToGmail.start()
        showInGmail.start()
        Task { [weak self] in
            await self?.center?.refreshAvailability()
            await self?.loadPlacements()
        }
    }

    public var unavailableText: String? {
        guard let center else {
            return String(localized: "Auto labels need Apple's on-device model, which isn't set up in this copy of Mail.")
        }
        if case .unavailable(let reason) = center.availability { return reason }
        return nil
    }

    public var canUseSwitch: Bool { availability.canEditSettings && unavailableText == nil }
    public var canAct: Bool { canUseSwitch && enabled.value && !isBusy }
    public var canPlace: Bool { importance != nil && !isBusy }

    public var statusText: String? { center?.lastMessage }

    public func classifyRecent() async {
        guard let center, canAct else { return }
        isBusy = true
        defer { isBusy = false }
        await center.classifyRecent()
    }

    public func reset() async {
        guard let center else { return }
        isBusy = true
        defer { isBusy = false }
        await center.reset()
    }

    private func accountIDs() async -> [AccountID] {
        (await AIThreadLoader.first(data.accounts()) ?? []).map(\.id)
    }

    public func loadPlacements() async {
        guard let importance, let account = await accountIDs().first,
              let rules = await AIThreadLoader.first(importance.rules(account)) else { return }
        var found: [String: Placement] = [:]
        for rule in rules where rule.match == .matcher {
            guard let category = AutoLabelRule.category(inValue: rule.value) else { continue }
            found[category] = rule.effect == .important ? .important : rule.effect == .neverImportant ? .other : .leave
        }
        placements = found
    }

    public func placement(_ category: String) -> Placement { placements[category] ?? .leave }

    public func setPlacement(_ placement: Placement, for category: String) async {
        guard let importance, let value = AutoLabelRule.value(for: category) else { return }
        errorText = nil
        isBusy = true
        defer { isBusy = false }
        do {
            for account in await accountIDs() {
                switch placement {
                case .leave:
                    let rules = await AIThreadLoader.first(importance.rules(account)) ?? []
                    let ids = rules.filter { $0.match == .matcher && AutoLabelRule.category(inValue: $0.value) == category }
                        .map(\.id)
                    if !ids.isEmpty { _ = try await importance.delete(ids) }
                case .important, .other:
                    _ = try await importance.apply(ImportanceChange(
                        kind: .matcher, account: account, value: value,
                        effect: placement == .important ? .important : .neverImportant))
                }
            }
            placements[category] = placement
        } catch {
            errorText = String(localized: "The rule for \(category) couldn't be saved.")
        }
    }

    public var errorMessage: String? {
        [errorText, enabled.errorMessage, applyToGmail.errorMessage, showInGmail.errorMessage].compactMap { $0 }.first
    }
}
