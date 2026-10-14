import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

public struct ReviewHostView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var isReviewLocation: Bool {
        if case .reviewQueue? = environment.router.active?.location { return true }
        return false
    }

    public var body: some View {
        let router = environment.router
        Group {
            if isReviewLocation, environment.modules.modules.contains(.review) {
                ReviewQueueView(model: environment.review, router: router)
            }
        }
        .task(id: router.active?.location) {
            if environment.modules.modules.contains(.review) {
                environment.review.locationChanged(router.active?.location, account: router.activeAccountID)
            }
        }
    }
}
