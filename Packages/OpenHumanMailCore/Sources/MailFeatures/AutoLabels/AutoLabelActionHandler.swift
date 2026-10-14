import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class AutoLabelActionHandler: ActionHandler {
    public static let ids: [ActionID] = [.autoLabelWrong]

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let feedback: ActionFeedback

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment?.autoLabels?.isOn == true ? .enabled : .hidden
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        guard request.id == .autoLabelWrong, let center = environment?.autoLabels,
              let thread = request.context.focusedThread else { return .notHandled }
        let (row, labels) = Self.row(of: thread, router: request.router)
        let feedback = self.feedback
        return .started(Task {
            do {
                if try await center.markWrong(thread, row: row, labels: labels) == nil {
                    feedback.failed("This conversation has no auto label")
                }
            } catch MailPortError.blockedBySafeMode {
                feedback.refuse(.autoLabelWrong, .safeMode)
            } catch {
                feedback.failed("Couldn't take the label off")
            }
        })
    }

    static func row(of thread: ThreadKey, router: AppRouter?) -> (ThreadRow?, [Int64: LabelInfo]) {
        let state = router?.accounts.first { $0.id == thread.account } ?? router?.active
        guard let list = state?.list else { return (nil, [:]) }
        return (list.row(for: thread), list.labels)
    }
}
