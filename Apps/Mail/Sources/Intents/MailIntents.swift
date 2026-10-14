import AppIntents
import Foundation
import MailFeatures

struct CountUnreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Count unread mail"
    static let description: IntentDescription? = IntentDescription("""
        How many conversations in your inbox are unread: the important ones (the Dock badge's number) or \
        all. Counts mail already on this Mac; nothing is fetched.
        """)
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Account", description: "All accounts when empty.") var account: AccountEntity?
    @Parameter(title: "Count", default: .important) var kind: UnreadKindAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Count \(\.$kind) unread mail") { \.$account }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let count = try await IntentBridge.current.countUnread(account: account?.id, kind: kind.value)
        return .result(value: count)
    }
}

struct FindConversationsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find conversations"
    static let description: IntentDescription? = IntentDescription("""
        Search mail already on this Mac. Each result has a link back to the conversation, the sender's name \
        and the date; the subject only if you allow it in Mail's settings. Message text is never included.
        """)
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Search for") var query: String
    @Parameter(title: "Account", description: "All accounts when empty.") var account: AccountEntity?
    @Parameter(title: "Limit", description: "1 to 20.", default: 5) var limit: Int
    @Parameter(title: "Important only", default: false) var importantOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find conversations matching \(\.$query)") {
            \.$account
            \.$limit
            \.$importantOnly
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ThreadEntity]> {
        let found = try await IntentBridge.current.findConversations(query, account: account?.id, limit: limit,
                                                                     importantOnly: importantOnly)
        return .result(value: found.map { ThreadEntity($0) })
    }
}

struct OpenMailboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open mailbox"
    static let description: IntentDescription? = IntentDescription("""
        Bring Mail forward on a mailbox, in one account or the one already showing.
        """)
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Mailbox", default: .inbox) var mailbox: MailboxAppEnum
    @Parameter(title: "Account") var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$mailbox)") { \.$account }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.current.openMailbox(mailbox.value, account: account?.id)
        return .result()
    }
}

struct OpenThreadIntent: AppIntent {
    static let title: LocalizedStringResource = "Open conversation"
    static let description: IntentDescription? = IntentDescription("""
        Bring Mail forward on a conversation.
        """)
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Conversation") var conversation: ThreadEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$conversation)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.current.openThread(conversation.id)
        return .result()
    }
}

struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search mail"
    static let description: IntentDescription? = IntentDescription("""
        Bring Mail forward with the results of a search.
        """)
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search for") var query: String
    @Parameter(title: "Account") var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search mail for \(\.$query)") { \.$account }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.current.searchMail(query, account: account?.id)
        return .result()
    }
}

struct NewMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "New message"
    static let description: IntentDescription? = IntentDescription("""
        Open a new message in Mail, optionally with recipients, a subject and text. It is never sent for \
        you: Mail shows the recipients and asks before the first send.
        """)
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Account") var account: AccountEntity?
    @Parameter(title: "To", description: "At most 50 addresses.") var to: [String]?
    @Parameter(title: "Subject") var subject: String?
    @Parameter(title: "Text") var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New message") {
            \.$to
            \.$subject
            \.$text
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.current.newMessage(account: account?.id, to: to ?? [], subject: subject, body: text)
        return .result()
    }
}

struct OpenReviewQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Open review queue"
    static let description: IntentDescription? = IntentDescription("""
        Bring Mail forward on the drafts an agent left for you to review.
        """)
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Account") var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Open the review queue") { \.$account }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.current.openReviewQueue(account: account?.id)
        return .result()
    }
}

struct MarkDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark done"
    static let description: IntentDescription? = IntentDescription("""
        Mark conversations done (out of the inbox), with an undo in Mail. Needs “Let Shortcuts change mail” \
        in Mail's settings.
        """)
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Conversations", description: "1 to 50.") var conversations: [ThreadEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$conversations) done")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentBridge.current.markDone(conversations.map(\.id)) { prompt in await ask(prompt) }
        return .result(dialog: "\(message)")
    }
}

struct SnoozeIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze"
    static let description: IntentDescription? = IntentDescription("""
        Snooze conversations until a time, with an undo in Mail. Needs “Let Shortcuts change mail” in Mail's \
        settings.
        """)
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Conversations", description: "1 to 50.") var conversations: [ThreadEntity]
    @Parameter(title: "Until") var until: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze \(\.$conversations) until \(\.$until)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentBridge.current.snooze(conversations.map(\.id), until: until) { prompt in
            await ask(prompt)
        }
        return .result(dialog: "\(message)")
    }
}

struct RemindMeIntent: AppIntent {
    static let title: LocalizedStringResource = "Remind me"
    static let description: IntentDescription? = IntentDescription("""
        Set a reminder on a conversation (on this Mac), with an undo in Mail. Needs “Let Shortcuts change \
        mail” in Mail's settings.
        """)
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Conversation") var conversation: ThreadEntity
    @Parameter(title: "At") var at: Date
    @Parameter(title: "Only if nobody replies", default: false) var onlyIfNoReply: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me about \(\.$conversation) at \(\.$at)") { \.$onlyIfNoReply }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await IntentBridge.current.remind(conversation.id, at: at, onlyIfNoReply: onlyIfNoReply) { prompt in
            await ask(prompt)
        }
        return .result(dialog: "\(message)")
    }
}

extension AppIntent {
    // Why: declined or no way to ask (unattended automation, locked screen) counts as no, so the change fails closed
    func ask(_ prompt: String) async -> Bool {
        let dialog: IntentDialog = "\(prompt)"
        do {
            try await requestConfirmation(dialog: dialog)
            return true
        } catch {
            return false
        }
    }
}
