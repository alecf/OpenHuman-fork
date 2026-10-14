import Foundation
import MailActions

@MainActor
final class InstantIntroActionHandler: ActionHandler {
    static let ids: [ActionID] = [.instantIntro]

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        .disabled(.notBuilt("Instant Intro"))
    }

    func perform(_ request: ActionRequest) -> ActionPerformance { .notHandled }
}
