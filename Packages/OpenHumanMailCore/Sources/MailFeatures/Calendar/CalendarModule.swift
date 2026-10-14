import Foundation
import MailActions
import MailModel

public struct CalendarModule: FeatureModule {
    public static let id = FeatureModuleID.calendar
    public static let defaultEnabled = true
    public init() {}

    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        guard env.calendar != nil else { return }
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: CalendarActionHandler(environment: env))
    }
}

extension ModuleList {
    @MainActor public static func configured(calendar: (any CalendarProviding)?) -> [any FeatureModule] {
        calendar == nil ? [] : [CalendarModule()]
    }
}

@MainActor
final class CalendarActionHandler: ActionHandler {
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard environment?.calendarSidebar != nil else { return .hidden }
        switch id {
        case .calendarToggleSidebar, .calendarCreateEvent, .calendarPreviousDay, .calendarNextDay, .calendarToday:
            return .enabled
        case .calendarSuggestReplyTimes:
            return context.focusedThread == nil || environment?.scheduling == nil ? .hidden : .enabled
        case .calendarInsertAvailability, .calendarComposerPreviousDay, .calendarComposerNextDay:
            return composer(context) == nil ? .hidden : .enabled
        default:
            guard let environment else { return .hidden }
            return CalendarWindowActions.availability(of: id, in: context, environment: environment)
        }
    }

    private func composer(_ context: ActionContext) -> ComposeSession? {
        guard let session = environment?.composeIfStarted?.session(id: context.composer), session.isOpen else { return nil }
        return session
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment, let sidebar = environment.calendarSidebar else { return .notHandled }
        switch request.id {
        case .calendarToggleSidebar:
            if request.source == .keyboard, sidebar.isVisible, let window = environment.calendarWindow,
               request.context.scope != .calendar {
                return .started(Task { await window.open(.day) })
            }
            sidebar.toggle()
            return .done
        case .calendarCreateEvent:
            guard let thread = request.context.focusedThread else { return .notHandled }
            if let router = request.router, router.reader?.thread != thread { router.open(thread) }
            return .started(Task { await sidebar.beginDraft(for: thread) })
        case .calendarPreviousDay, .calendarNextDay, .calendarToday:
            if let window = environment.calendarWindowIfStarted, window.isOpen {
                let id = request.id
                return .started(Task {
                    if id == .calendarToday { await window.goToToday() } else { await window.move(by: id == .calendarNextDay ? 1 : -1) }
                })
            }
            sidebar.setVisible(true)
            let id = request.id
            return .started(Task {
                if id == .calendarToday { await sidebar.goToToday() } else { await sidebar.moveDay(by: id == .calendarNextDay ? 1 : -1) }
            })
        case .calendarSuggestReplyTimes:
            guard let thread = request.context.focusedThread, let scheduling = environment.scheduling else {
                return .notHandled
            }
            if let router = request.router, router.reader?.thread != thread { router.open(thread) }
            return .started(Task { await scheduling.openOptions(for: thread) })
        case .calendarInsertAvailability:
            guard let session = composer(request.context) else { return .notHandled }
            return .started(Task { await sidebar.insertAvailability(into: session) })
        case .calendarComposerPreviousDay, .calendarComposerNextDay:
            guard composer(request.context) != nil else { return .notHandled }
            sidebar.setVisible(true)
            let delta = request.id == .calendarComposerNextDay ? 1 : -1
            return .started(Task { await sidebar.moveDay(by: delta) })
        default:
            return CalendarWindowActions.perform(request, environment: environment)
        }
    }
}
