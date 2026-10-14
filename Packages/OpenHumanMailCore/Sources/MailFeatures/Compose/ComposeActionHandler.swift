import Foundation
import MailActions
import MailModel
import MailRender

@MainActor
final class ComposeActionHandler: ActionHandler {
    static let coreIDs: [ActionID] = [.send, .discardDraft, .chooseFrom, .attachFiles, .popOutComposer, .insertSnippet,
                                      .saveSnippet, .includeOriginalAttachments, .toggleFormatBar]
    static let sendLaterIDs: [ActionID] = [.sendLater, .cancelSendLater]
    static let remindersIDs: [ActionID] = [.composeRemind]

    private weak var environment: AppEnvironment?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var manager: ComposeManager? { environment?.composeIfStarted }

    private func session(_ context: ActionContext) -> ComposeSession? {
        guard let session = manager?.session(id: context.composer), session.isOpen else { return nil }
        return session
    }

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let session = session(context) else { return .hidden }
        switch id {
        case .chooseFrom:
            return session.offersFromPicker ? .enabled : .hidden
        case .cancelSendLater:
            return session.sendAt == nil ? .hidden : .enabled
        case .sendLater:
            return session.source == .user || session.review == .approved
                ? .enabled : .disabled(.other(String(localized: "Review this agent draft before scheduling it")))
        case .popOutComposer:
            return session.placement == .window ? .hidden : .enabled
        case .attachFiles:
            return manager?.chooseFiles == nil ? .hidden : .enabled
        case .saveSnippet:
            return session.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .disabled(.other(String(localized: "Write something first"))) : .enabled
        case .includeOriginalAttachments:
            return (session.mode == .reply || session.mode == .replyAll) && session.replyTo != nil ? .enabled : .hidden
        default:
            return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let manager, let session = session(request.context) else { return .notHandled }
        switch request.id {
        case .send:
            return manager.send(session)
        case .sendLater:
            return manager.sendLater(session)
        case .cancelSendLater:
            return manager.cancelSendLater(session)
        case .discardDraft:
            return manager.discard(session)
        case .chooseFrom:
            session.isFromPickerOpen = true
            return .done
        case .attachFiles:
            manager.chooseFiles?(session)
            return .done
        case .popOutComposer:
            manager.popOut(session)
            return .done
        case .insertSnippet:
            session.openSnippetPicker()
            return .done
        case .saveSnippet:
            return .started(Task { await manager.saveAsSnippet(session) })
        case .includeOriginalAttachments:
            return .started(Task { await manager.includeOriginalAttachments(session) })
        case .toggleFormatBar:
            manager.toggleFormatBar()
            return .done
        case .composeRemind:
            return manager.remind(from: session) ? .done : .notHandled
        default:
            return .notHandled
        }
    }
}

extension ComposeManager {
    func saveAsSnippet(_ session: ComposeSession) async {
        guard let commands = environment.commands else { return }
        let html = ComposeSerializer.html(session.document, signature: nil)
        let subject = session.subject.trimmingCharacters(in: .whitespaces)
        let name = subject.isEmpty ? String(session.plainText.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines) : subject
        let variables = SnippetExpander.variableNames(in: session.plainText).map { SnippetVariableInfo(name: $0) }
        do {
            let saved = try await commands.upsertSnippet(SnippetInfo(account: session.account.id, name: name,
                                                                     subject: subject.isEmpty ? nil : subject,
                                                                     bodyHTML: html, variables: variables))
            environment.notices.post(String(localized: "Saved snippet “\(saved.name)”"), style: .info,
                                     duration: NoticeCenter.infoDuration)
        } catch {
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            session.notice = ComposeSession.Notice(.error, String(localized: "Couldn't save the snippet. \(detail)"))
        }
    }

    func includeOriginalAttachments(_ session: ComposeSession) async {
        guard let thread = session.thread, let original = session.replyTo else { return }
        let detail = await Self.first(environment.data.threadDetail(thread)) ?? nil
        let files = detail?.messages.first { $0.id == original }?.attachments.filter { !$0.isInline } ?? []
        let added = session.addOriginalAttachments(files)
        if files.isEmpty {
            session.notice = ComposeSession.Notice(.info, String(localized: "The message you're answering has no attachments."))
        } else if added == 0 {
            session.notice = ComposeSession.Notice(.info, String(localized: "Its attachments are already in this reply."))
        }
    }
}

public struct SendLaterModule: FeatureModule {
    public static let id = FeatureModuleID.sendLater
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.actions(ComposeActionHandler.sendLaterIDs.compactMap(ActionCatalog.descriptor),
                         handler: ComposeActionHandler(environment: env))
        registry.actions(DraftRowActionHandler.sendLaterIDs.compactMap(ActionCatalog.descriptor),
                         handler: DraftRowActionHandler(environment: env))
        registry.location(.system(.scheduled), title: "Scheduled", chord: .sequence("g", "y"))
        registry.scheduleKind(.sendLater)
    }
}
