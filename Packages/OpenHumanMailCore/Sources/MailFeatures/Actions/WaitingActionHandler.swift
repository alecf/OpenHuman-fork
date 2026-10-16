import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class WaitingActionHandler: ActionHandler {
    public static let ids: [ActionID] = [.toggleWaiting]

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let feedback: ActionFeedback

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment?.waiting == nil ? .hidden : .enabled
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        guard request.id == .toggleWaiting, let port = environment?.waiting, let undo = environment?.undo,
              let thread = request.context.focusedThread else { return .notHandled }
        let leaving = request.context.location == .system(.waiting)
        let choice: WaitingChoice = leaving ? .notWaiting : .waiting
        let title: LocalizedStringResource = leaving ? "Not waiting" : "Waiting for a reply"
        var reopens: UndoCoordinator.Entry.Reopen?
        if leaving, let router = request.router,
           let state = router.accounts.first(where: { $0.id == thread.account }) ?? router.active {
            reopens = ThreadActionHandler.advance(past: [thread], in: state, router: router)
        }
        let feedback = self.feedback
        return .started(Task {
            do {
                try await undo.perform(title, threads: [thread], via: port, reopens: reopens) {
                    try await port.setChoice(choice, for: thread)
                }
            } catch {
                feedback.failed(leaving ? "Couldn't mark the conversation as not waiting" : "Couldn't mark the conversation as waiting")
            }
        })
    }
}
