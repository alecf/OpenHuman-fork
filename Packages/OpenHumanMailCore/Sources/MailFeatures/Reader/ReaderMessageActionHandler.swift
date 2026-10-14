import Foundation
import MailActions
import MailModel

@MainActor
final class ReaderMessageActionHandler: ActionHandler {
    static let ids: [ActionID] = [.nextMessage, .previousMessage, .toggleMessage, .expandAllMessages, .toggleQuotedText,
                                  .showImages, .showNewMessages, .findInConversation]

    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let reader = Self.reader(host, context) else { return .hidden }
        if id == .findInConversation { return .enabled }
        guard reader.focusedMessage != nil else { return .hidden }
        switch id {
        case .nextMessage: return reader.canFocusNext ? .enabled : .disabled(.other("This is the newest message"))
        case .previousMessage: return reader.canFocusPrevious ? .enabled : .disabled(.other("This is the oldest message"))
        case .showImages: return reader.canShowImages ? .enabled : .disabled(.other("No images are hidden"))
        case .showNewMessages: return reader.pendingMessages.isEmpty ? .disabled(.other("No new messages")) : .enabled
        default: return .enabled
        }
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let reader = Self.reader(request.host, request.context) else { return .notHandled }
        switch request.id {
        case .nextMessage: return reader.focusNext() ? .done : .notHandled
        case .previousMessage: return reader.focusPrevious() ? .done : .notHandled
        case .toggleMessage: reader.toggleFocused()
        case .expandAllMessages: reader.expandAll()
        case .toggleQuotedText: reader.toggleQuotedText()
        case .showImages: reader.showImages()
        case .showNewMessages: reader.showNewMessages()
        case .findInConversation: reader.requestFind()
        default: return .notHandled
        }
        return .done
    }

    private static func reader(_ host: (any ActionHost)?, _ context: ActionContext) -> ReaderModel? {
        guard let router = host as? AppRouter, router.mode == .reader, let reader = router.reader,
              reader.thread == context.focusedThread, reader.state == .loaded else { return nil }
        return reader
    }
}
