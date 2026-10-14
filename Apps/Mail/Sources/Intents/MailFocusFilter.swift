import AppIntents
import AppKit
import CoreGraphics
import Foundation
import MailFeatures
import OpenHumanCore

enum FocusOpenOnAppEnum: String, AppEnum {
    case important, inbox, stay

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Open on"
    static let caseDisplayRepresentations: [FocusOpenOnAppEnum: DisplayRepresentation] = [
        .important: "Important",
        .inbox: "Inbox",
        .stay: "Where I left it",
    ]

    var value: FocusFilterState.OpenOn {
        switch self {
        case .important: .important
        case .inbox: .inbox
        case .stay: .stay
        }
    }
}

struct MailFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Put an account first"
    static let description: IntentDescription? = IntentDescription("""
        Bring an account forward in Mail while this Focus is on. Nothing is hidden: every account stays one key \
        away, and held notifications are summed up when the Focus ends.
        """)

    @Parameter(title: "Accounts") var accounts: [AccountEntity]?
    @Parameter(title: "Open on", default: .important) var openOn: FocusOpenOnAppEnum
    @Parameter(title: "Hold notifications from other accounts", default: false) var holdOtherNotifications: Bool
    @Parameter(title: "Badge counts only these accounts", default: false) var badgeOnlyTheseAccounts: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Put \(\.$accounts) first, open on \(\.$openOn)") {
            \.$holdOtherNotifications
            \.$badgeOnlyTheseAccounts
        }
    }

    var displayRepresentation: DisplayRepresentation {
        let names = (accounts ?? []).map(\.title).joined(separator: ", ")
        let title = names.isEmpty ? "No account chosen" : "\(names) first"
        let place: String = switch openOn {
        case .important: "Opens on Important"
        case .inbox: "Opens on Inbox"
        case .stay: "Stays where you left it"
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(place)")
    }

    var appContext: FocusFilterAppContext { FocusFilterAppContext(notificationFilterPredicate: nil) }

    var state: FocusFilterState? {
        let ids = (accounts ?? []).compactMap { Int64($0.id) }.map { AccountID($0) }
        guard !ids.isEmpty else { return nil }
        return FocusFilterState(accounts: ids, openOn: openOn.value, holdOtherNotifications: holdOtherNotifications,
                                badgeOnlyTheseAccounts: badgeOnlyTheseAccounts)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.current.applyFocusFilter(state)
        return .result()
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [MailFocusFilter] {
        await suggestions()
    }

    @MainActor
    static func suggestions() async -> [MailFocusFilter] {
        await IntentBridge.current.focusAccounts().map { account in
            var filter = MailFocusFilter()
            filter.accounts = [AccountEntity(account)]
            filter.openOn = .important
            filter.holdOtherNotifications = false
            filter.badgeOnlyTheseAccounts = false
            return filter
        }
    }

    @MainActor
    static func currentState() async -> FocusFilterState? {
        guard let current = try? await MailFocusFilter.current else { return nil }
        return current.state
    }
}

@MainActor
enum AuthorActivity {
    static func isTyping(within seconds: TimeInterval = 10) -> Bool {
        guard NSApp.isActive else { return false }
        if NSApp.keyWindow?.firstResponder is NSText { return true }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < seconds
    }
}
