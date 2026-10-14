import Foundation
import MailActions
import MailModel

public enum ReaderActions {
    public static var threadActions: [ActionDescriptor] {
        ActionCatalog.all.filter { $0.scopes.contains(.reader) && $0.category == .thread && $0.appearsInMenu
            && symbol(for: $0.id) != nil }
    }

    public static let primaryThreadActionIDs: [ActionID] = [.markDone, .snooze, .remind]

    public static let navigationActionIDs: [ActionID] = [.previousThread, .nextThread]

    public static var navigationActions: [ActionDescriptor] {
        navigationActionIDs.compactMap { id in ActionCatalog.all.first { $0.id == id && $0.scopes.contains(.reader) } }
    }

    public static func split(_ offered: [ActionDescriptor]) -> (primary: [ActionDescriptor], more: [ActionDescriptor]) {
        let primary = primaryThreadActionIDs.compactMap { id in offered.first { $0.id == id } }
        return (primary, offered.filter { !primaryThreadActionIDs.contains($0.id) })
    }

    public static var moreMenuSections: [[ActionDescriptor]] {
        let thread = ActionCatalog.all.filter {
            $0.scopes.contains(.reader) && $0.category == .thread && $0.appearsInMenu && $0.target != ActionTarget.none
                && !primaryThreadActionIDs.contains($0.id)
        }
        return [messageActions, thread, ActionCatalog.all.filter { $0.id == .printConversation }]
    }

    @MainActor
    public static func offeredMoreMenu(registry: ActionRegistry?, host: (any ActionHost)?,
                                       context: ActionContext) -> [[ActionDescriptor]] {
        moreMenuSections.map { section in
            section.filter { decide($0, registry: registry, host: host, context: context) != .hidden }
                .map { registry?.descriptor($0.id) ?? $0 }
        }.filter { !$0.isEmpty }
    }

    public static let messageActionIDs: [ActionID] = [.reply, .replyAll, .forward]

    public static var messageActions: [ActionDescriptor] {
        messageActionIDs.compactMap { id in
            ActionCatalog.all.first { $0.id == id && $0.scopes.contains(.reader) && symbol(for: id) != nil }
        }
    }

    public struct Availability: Equatable, Sendable {
        public let isEnabled: Bool
        public let help: String

        public init(isEnabled: Bool, help: String) {
            self.isEnabled = isEnabled
            self.help = help
        }
    }

    public static func availability(_ action: ActionDescriptor, decided: ActionAvailability,
                                    title: String? = nil) -> Availability {
        switch decided {
        case .enabled:
            let keys = action.shortcutHint.map { "  \($0)" } ?? ""
            return Availability(isEnabled: true, help: (title ?? action.title) + keys)
        case .disabled(let reason):
            return Availability(isEnabled: false, help: reason.description)
        case .hidden:
            return Availability(isEnabled: false, help: "\(action.title) is not available")
        }
    }

    @MainActor
    public static func context(host: (any ActionHost)?, thread: ThreadKey, lastMessage: MessageKey?,
                               safeMode: SafeModeInfo, isStarred: Bool = false) -> ActionContext {
        var c = (host as? AppRouter)?.contentContext() ?? host?.actionContext() ?? ActionContext()
        c.targets.allStarred = isStarred
        c.scope = .reader
        c.selection = [thread]
        c.focusedThread = thread
        c.focusedMessage = lastMessage
        c.safeMode = safeMode
        return c
    }

    @MainActor
    public static func decide(_ action: ActionDescriptor, registry: ActionRegistry?, host: (any ActionHost)?,
                              context: ActionContext) -> ActionAvailability {
        guard let registry else { return ActionRules.availability(action, in: context) }
        return registry.availability(action.id, host: host, context: context)
    }

    @MainActor
    public static func offeredThreadActions(registry: ActionRegistry?, host: (any ActionHost)?,
                                            context: ActionContext) -> [ActionDescriptor] {
        threadActions.filter { decide($0, registry: registry, host: host, context: context) != .hidden }
    }

    @MainActor
    public static func availability(_ action: ActionDescriptor, registry: ActionRegistry?, host: (any ActionHost)?,
                                    context: ActionContext) -> Availability {
        availability(action, decided: decide(action, registry: registry, host: host, context: context),
                     title: ActionRules.title(for: action, in: context))
    }

    public static func activeSymbol(for id: ActionID) -> String? {
        id == .toggleStar ? "star.fill" : nil
    }

    public static func symbol(for id: ActionID) -> String? {
        switch id.rawValue {
        case "thread.done": "checkmark"
        case "thread.trash": "trash"
        case "thread.snooze": "clock"
        case "thread.label": "tag"
        case "thread.move": "folder"
        case "thread.toggleStar": "star"
        case "thread.toggleRead": "envelope.badge"
        case "thread.spam": "exclamationmark.octagon"
        case "thread.moveToInbox": "tray.and.arrow.down"
        case "reminders.set": "bell"
        case "draft.open": "pencil"
        case "scheduledSend.reschedule": "calendar.badge.clock"
        case "scheduledSend.cancel": "calendar.badge.minus"
        case "compose.reply": "arrowshape.turn.up.left"
        case "compose.replyAll": "arrowshape.turn.up.left.2"
        case "compose.forward": "arrowshape.turn.up.right"
        case "nav.previousThread": "chevron.up"
        case "nav.nextThread": "chevron.down"
        default: nil
        }
    }
}
