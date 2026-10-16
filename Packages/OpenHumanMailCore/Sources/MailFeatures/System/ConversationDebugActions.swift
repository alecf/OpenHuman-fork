import Foundation
import MailActions
import MailModel
import OpenHumanCore

@MainActor
struct ConversationDebugCollector {
    unowned let environment: AppEnvironment

    func collect(_ thread: ThreadKey, options: ConversationDebugOptions) async -> ConversationDebugInput? {
        let data = environment.data
        guard let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil else { return nil }
        let accounts = await AIThreadLoader.first(data.accounts()) ?? []
        let position = accounts.firstIndex { $0.id == thread.account }
        let account = position.map { accounts[$0] }
        var own = Set<String>()
        if let account {
            own.insert(account.email)
            for identity in account.sendAs { own.insert(identity.email) }
        }
        let labels = await AIThreadLoader.first(data.labels(thread.account)) ?? []
        let splits = await AIThreadLoader.first(data.splits(thread.account)) ?? []
        let row = try? await data.localThread(thread.account, gmailThreadID: thread.gmailThreadID)
        let snapshot = try? await data.diagnosticsSnapshot()
        let index = (position ?? 0) + 1
        let importance = try? await environment.importance?.explain(thread)
        let store = try? await data.conversationDebugFacts(thread)
        return ConversationDebugInput(
            app: SystemCenter.appInfo(isFake: environment.isFake), now: Date(), accountIndex: index,
            isLiveAccount: environment.isLiveAccount,
            sync: snapshot?.accounts.first { $0.index == index }, detail: detail, row: row ?? nil, labels: labels,
            splits: splits, importance: importance, ownAddresses: own, store: store ?? nil,
            logLines: environment.system.logLines(), options: options)
    }
}

@MainActor
final class ConversationDebugActionHandler: ActionHandler {
    static let ids: [ActionID] = [.copyConversationDebug, .saveConversationDebug]
    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        environment == nil ? .hidden : .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment, let thread = request.context.focusedThread ?? request.context.selection.first else {
            return .notHandled
        }
        switch request.id {
        case .copyConversationDebug:
            return .started(Task { await Self.run(thread, environment: environment, save: false) })
        case .saveConversationDebug:
            return .started(Task { await Self.run(thread, environment: environment, save: true) })
        default:
            return .notHandled
        }
    }

    static func run(_ thread: ThreadKey, environment: AppEnvironment, save: Bool) async {
        let platform = environment.system.platform
        guard let options = platform.confirmConversationDebug() else { return }
        var destination: URL?
        if save {
            guard let url = platform.chooseConversationDebugFile(suggestedFileName(now: Date())) else { return }
            destination = url
        }
        guard let input = await ConversationDebugCollector(environment: environment).collect(thread, options: options) else {
            environment.notices.post("Couldn't read this conversation", style: .error, duration: NoticeCenter.infoDuration)
            return
        }
        let text = ConversationDebugReport.build(input)
        if let destination {
            do {
                try Data(text.utf8).write(to: destination, options: .atomic)
                environment.notices.post("Debug info saved", style: .info, duration: NoticeCenter.infoDuration)
            } catch {
                environment.notices.post("Couldn't save debug info", style: .error, duration: NoticeCenter.infoDuration)
            }
        } else {
            platform.copyToClipboard(text)
            environment.notices.post("Debug info copied", style: .info, duration: NoticeCenter.infoDuration)
        }
    }

    static func suggestedFileName(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        return String(format: "Mail-Conversation-Debug-%04d%02d%02d-%02d%02d%02d.json", c.year ?? 0, c.month ?? 0,
                      c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
