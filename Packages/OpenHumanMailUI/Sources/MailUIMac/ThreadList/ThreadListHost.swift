import AppKit
import MailActions
import MailFeatures
import MailModel
import OpenHumanCore

@MainActor
public protocol ThreadListHost: AnyObject {
    func threadListPerform(_ action: ActionID) -> Bool
    func threadListCanPerform(_ action: ActionID) -> Bool
    func threadListSelection(for model: ThreadListModel) -> SelectionModel?
    func threadListConnectivity(for account: AccountID) -> ConnectivityState?
    func threadListTitle(for location: MailLocation) -> String
    func threadListMenuEntry(_ action: ActionID) -> ThreadListMenuEntry
    func threadListDescriptors() -> [ActionDescriptor]
    func threadListAddsRelatedResults() -> Bool
    func threadListFollowUpReason(for row: ThreadRow) -> String?
}

public struct ThreadListMenuEntry: Equatable, Sendable {
    public var title: String
    public var availability: ActionAvailability
    public var reason: String?

    public init(title: String, availability: ActionAvailability, reason: String? = nil) {
        self.title = title
        self.availability = availability
        self.reason = reason
    }
}

extension ThreadListHost {
    public func threadListMenuEntry(_ action: ActionID) -> ThreadListMenuEntry {
        ThreadListMenuEntry(title: ActionCatalog.descriptor(action)?.title ?? action.rawValue,
                            availability: threadListCanPerform(action) ? .enabled : .hidden)
    }

    public func threadListDescriptors() -> [ActionDescriptor] { ActionCatalog.all }

    public func threadListAddsRelatedResults() -> Bool { false }

    public func threadListFollowUpReason(for row: ThreadRow) -> String? { nil }
}

public enum ThreadListActionIDs {
    public static let snooze = ActionID("thread.snooze")
    public static let label = ActionID("thread.label")
    public static let toggleRead = ActionID("thread.toggleRead")
    public static let reply = ActionID("compose.reply")
}

@MainActor
final class RouterThreadListHost: ThreadListHost {
    private weak var router: AppRouter?

    init(router: AppRouter) {
        self.router = router
    }

    func threadListPerform(_ action: ActionID) -> Bool { router?.performClick(action) ?? false }

    func threadListCanPerform(_ action: ActionID) -> Bool { router?.isEnabledForClick(action) ?? false }

    func threadListSelection(for model: ThreadListModel) -> SelectionModel? {
        router?.accounts.first { $0.list === model }?.selection
    }

    func threadListConnectivity(for account: AccountID) -> ConnectivityState? {
        router?.environment.status.connectivity[account]
    }

    func threadListAddsRelatedResults() -> Bool {
        guard let environment = router?.environment, environment.smartSearchEnabled else { return false }
        return environment.status.smartSearch.addsRelatedResults
    }

    func threadListFollowUpReason(for row: ThreadRow) -> String? {
        guard let environment = router?.environment, environment.ai != nil, row.reminderAt != nil else { return nil }
        return environment.followUps.reason(for: row)
    }

    func threadListMenuEntry(_ action: ActionID) -> ThreadListMenuEntry {
        guard let router, let descriptor = router.environment.actions.descriptor(action) else {
            return ThreadListMenuEntry(title: action.rawValue, availability: .hidden)
        }
        let context = router.contentContext()
        let availability = router.environment.actions.availability(action, host: router, context: context)
        let reason = availability.reason.map { PaletteController.unavailableText($0) ?? $0.description }
        return ThreadListMenuEntry(title: ActionRules.title(for: descriptor, in: context), availability: availability,
                                   reason: reason)
    }

    func threadListDescriptors() -> [ActionDescriptor] { router?.environment.actions.descriptors ?? ActionCatalog.all }

    func threadListTitle(for location: MailLocation) -> String {
        guard let router else { return "" }
        let state = router.accounts.first { $0.location == location } ?? router.active
        return state?.title(for: location) ?? ""
    }
}
