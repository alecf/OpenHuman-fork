import Foundation
import MailModel

@MainActor
public final class FailedOperationNotices {
    private weak var environment: AppEnvironment?
    private var said: Set<FailedOperationInfo.ID> = []

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func run() async {
        guard let data = environment?.data else { return }
        do {
            for try await failures in data.failedOperations(nil) {
                guard !Task.isCancelled else { return }
                present(failures)
            }
        } catch {}
    }

    func present(_ failures: [FailedOperationInfo]) {
        for failure in failures.sorted(by: { ($0.failedAt, $0.id) < ($1.failedAt, $1.id) }) where !said.contains(failure.id) {
            said.insert(failure.id)
            post(failure)
        }
    }

    private func post(_ failure: FailedOperationInfo) {
        guard let notices = environment?.notices else { return }
        let dismiss = NoticeCenter.Choice(String(localized: "Dismiss")) { [weak self] in await self?.dismiss(failure) }
        guard let command = Self.command(for: failure) else {
            notices.post(Self.message(for: failure), style: .error, actionTitle: String(localized: "Dismiss"),
                         duration: nil) { [weak self] in await self?.dismiss(failure) }
            return
        }
        let retry = NoticeCenter.Choice(String(localized: "Retry")) { [weak self] in await self?.retry(failure, command) }
        notices.postChoice(Self.message(for: failure), retry, dismiss, style: .error, duration: nil)
    }

    private func retry(_ failure: FailedOperationInfo, _ command: MailCommand) async {
        guard let environment else { return }
        await environment.actions.threadActions?.retry(command)
        await dismiss(failure)
    }

    private func dismiss(_ failure: FailedOperationInfo) async {
        guard let commands = environment?.commands else { return }
        do {
            try await commands.dismissFailedOperation(failure.id)
        } catch {
            environment?.notices.post(String(localized: "Couldn't clear the notice. Try again."), style: .error)
        }
    }

    nonisolated static func command(for failure: FailedOperationInfo) -> MailCommand? {
        let threads = failure.threads
        guard !threads.isEmpty else { return nil }
        switch failure.kind {
        case "markDone": return .markDone(threads)
        case "moveToInbox": return .moveToInbox(threads)
        case "trash": return .trash(threads)
        case "untrash": return .untrash(threads)
        case "markRead": return .markRead(threads)
        case "markUnread": return .markUnread(threads)
        case "star": return .star(threads)
        case "unstar": return .unstar(threads)
        case "markSpam": return .markSpam(threads)
        case "markNotSpam": return .markNotSpam(threads)
        default: return nil
        }
    }

    nonisolated static func message(for failure: FailedOperationInfo) -> String {
        if let command = command(for: failure) { return Titles.failure(command) }
        let n = failure.threads.count
        switch failure.kind {
        case "sendDraft": return String(localized: "Gmail didn't send a message. It's still in Drafts.")
        case "saveDraft": return String(localized: "Couldn't save a draft to Gmail")
        case "deleteDraft": return String(localized: "Couldn't delete a draft in Gmail")
        case "createLabel": return String(localized: "Couldn't create a label in Gmail")
        default:
            if n == 0 { return String(localized: "Gmail refused a change") }
            return n == 1 ? String(localized: "Couldn't change labels on 1 conversation")
                          : String(localized: "Couldn't change labels on \(n) conversations")
        }
    }
}
