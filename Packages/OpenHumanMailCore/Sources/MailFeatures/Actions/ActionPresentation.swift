import Foundation
import MailActions
import MailModel
import OpenHumanCore

public enum LabelPickerMode: String, Sendable, Hashable {
    case label
    case move
    case navigate
}

public enum ComposeRequest: Sendable, Hashable {
    case new
    case newWindow
    case reply(ThreadKey)
    case replyAll(ThreadKey)
    case forward(ThreadKey)
    case mailto(EmailAddress, subject: String?)
}

public enum ActionPresentation: Sendable {
    case palette
    case shortcutHelp
    case search
    case labelPicker(targets: [ThreadKey], mode: LabelPickerMode)
    case snoozePicker(targets: [ThreadKey])
    case remindPicker(thread: ThreadKey)
    case compose(ComposeRequest)
    case openURL(URL)
    case getMeToZero(account: AccountID)
    case askInbox(question: String?)

    public var kind: Kind {
        switch self {
        case .palette: .palette
        case .shortcutHelp: .shortcutHelp
        case .search: .search
        case .labelPicker: .labelPicker
        case .snoozePicker: .snoozePicker
        case .remindPicker: .remindPicker
        case .compose: .compose
        case .openURL: .openURL
        case .getMeToZero: .getMeToZero
        case .askInbox: .askInbox
        }
    }

    public enum Kind: Sendable, Hashable, CaseIterable {
        case palette, shortcutHelp, search, labelPicker, snoozePicker, remindPicker, compose, openURL, getMeToZero, askInbox
    }
}

@MainActor
public protocol ActionPresenting: AnyObject, Sendable {
    func canPresent(_ kind: ActionPresentation.Kind) -> Bool
    func present(_ presentation: ActionPresentation)
}
