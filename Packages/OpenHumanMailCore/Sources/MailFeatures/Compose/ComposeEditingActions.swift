import Foundation
import MailActions
import MailModel

@MainActor
public protocol ComposeFormatting: AnyObject {
    func applyFormatting(_ action: ActionID) -> Bool
}

@MainActor
final class ComposeEditingActionHandler: ActionHandler {
    static let ids: [ActionID] = [.showCc, .showBcc, .focusTo, .closeComposer] + ActionCatalog.formatIDs

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
        if ActionCatalog.formatIDs.contains(id) {
            return (session.editor as? ComposeFormatting) == nil ? .hidden : .enabled
        }
        return .enabled
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let session = session(request.context) else { return .notHandled }
        switch request.id {
        case .showCc:
            session.showCc()
            session.cc.requestFocus()
        case .showBcc:
            session.showBcc()
            session.bcc.requestFocus()
        case .focusTo:
            session.to.requestFocus()
        case .closeComposer:
            guard let manager else { return .notHandled }
            manager.close(session)
        default:
            guard let editor = session.editor as? ComposeFormatting, editor.applyFormatting(request.id) else {
                return .notHandled
            }
        }
        return .done
    }
}

extension ComposeManager {
    public var actionDescriptors: [ActionDescriptor] { environment.actions.descriptors }

    public var actionKeymapRevision: Int { environment.actions.keymapRevision }
}
