import Foundation
import MailModel

extension ThreadActionHandler {
    func keepDraft(of thread: ThreadKey) {
        guard let environment, let compose = environment.composeIfStarted,
              let session = compose.sessions.first(where: { $0.isOpen && $0.placement == .docked(thread) }),
              session.hasUserEdits || session.resumed else { return }
        Task { _ = await session.save() }
        environment.notices.post(String(localized: "Your draft stays in Drafts"), style: .info,
                                 duration: NoticeCenter.infoDuration)
    }
}
