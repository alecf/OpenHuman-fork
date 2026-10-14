import Foundation
import MailModel
import OpenHumanCore
import OpenHumanLinks

public struct LinkOutcome: Equatable, Sendable {
    public let message: String
    public let handled: Bool

    public init(_ message: String, handled: Bool) {
        self.message = message
        self.handled = handled
    }
}

extension AppRouter {
    @discardableResult
    public func route(_ link: MailLink) -> LinkOutcome {
        switch link {
        case .thread(let ref, let threadID):
            guard let state = resolve(ref) else { return Self.unknownAccount(ref) }
            switchAccount(to: state.id)
            if let row = state.list?.rows.first(where: { $0.id.gmailThreadID.rawValue == threadID }) {
                open(row.id)
                return LinkOutcome("Opened thread \(threadID).", handled: true)
            }
            guard let commands = environment.commands else {
                return LinkOutcome("That conversation isn't in this list.", handled: false)
            }
            let account = state.id
            let name = StatusBanner.name(state.account)
            Task { [weak self] in
                let key = try? await commands.fetchThreadNow(account, gmailThreadID: GmailThreadID(threadID))
                guard let self else { return }
                if let key, self.activeAccountID == account {
                    self.open(key)
                } else if key == nil {
                    self.environment.notices.post("Conversation not found in \(name)", style: .info,
                                                  duration: NoticeCenter.infoDuration)
                }
            }
            return LinkOutcome("Opening thread \(threadID)…", handled: true)
        case .search(let query, let ref):
            var target = active
            if let ref {
                guard let named = resolve(ref) else { return Self.unknownAccount(ref) }
                target = named
            }
            guard let state = target else { return LinkOutcome("No account is open.", handled: false) }
            switchAccount(to: state.id)
            go(to: .search(query))
            return LinkOutcome("Showing search results.", handled: true)
        case .draft(let ref, let draftID):
            guard let state = resolve(ref) else { return Self.unknownAccount(ref) }
            environment.compose.openDraft(link: draftID, account: state.id)
            return LinkOutcome("Opening draft \(draftID)…", handled: true)
        case .review(let refs):
            let targets = refs.map { ref in
                ReviewTarget(account: ref.account.flatMap(resolve)?.id, draftID: ref.draftID)
            }
            guard let first = targets.first(where: { $0.account != nil })?.account else {
                if let ref = refs.first?.account { return Self.unknownAccount(ref) }
                return LinkOutcome("The link names no drafts.", handled: false)
            }
            switchAccount(to: first)
            go(to: .reviewQueue(targets.map { DraftKey($0.draftID) }))
            environment.review.showLink(targets)
            return LinkOutcome("Showing \(targets.count) draft\(targets.count == 1 ? "" : "s") to review.", handled: true)
        case .compose(let prefill):
            var target = active
            if let ref = prefill.account {
                guard let named = resolve(ref) else { return Self.unknownAccount(ref) }
                target = named
            }
            guard let state = target else { return LinkOutcome("No account is open.", handled: false) }
            guard environment.compose.open(link: prefill, account: state.id) != nil else {
                return LinkOutcome("No account is open.", handled: false)
            }
            return LinkOutcome("Opened a new message from the link.", handled: true)
        case .settings(let target):
            let navigator = environment.settingsNavigator
            guard navigator.canOpen else { return LinkOutcome("Settings can't open from here.", handled: false) }
            switch target {
            case .page(let page): navigator.open(page)
            case .aiPrompts(let promptID): navigator.openPrompt(promptID)
            }
            return LinkOutcome("Opened Settings.", handled: true)
        }
    }

    func resolve(_ ref: AccountRef) -> AccountState? {
        accounts.first { $0.account.email.caseInsensitiveCompare(ref.raw) == .orderedSame }
            ?? accounts.first { $0.account.alias == ref.raw }
    }

    static func unknownAccount(_ ref: AccountRef) -> LinkOutcome {
        LinkOutcome("No account named “\(ref.raw)”.", handled: false)
    }
}
