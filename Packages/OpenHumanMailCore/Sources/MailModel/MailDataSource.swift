import Foundation
import OpenHumanCore

public protocol MailDataSource: Sendable {
    func accounts() -> AsyncThrowingStream<[Account], Error>
    func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error>
    func splits(_ account: AccountID) -> AsyncThrowingStream<[SplitInfo], Error>
    func counts(_ account: AccountID) -> AsyncThrowingStream<MailboxCountsInfo, Error>
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error>
    func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?, limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?)
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error>
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error>
    func storedBody(_ key: MessageKey) async throws -> MessageContent?
    func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL
    func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error>
    func searchGmail(_ query: String, account: AccountID) async throws -> Int
    func drafts(_ account: AccountID?, review: Bool) -> AsyncThrowingStream<[DraftSummary], Error>
    func draft(_ key: DraftKey) -> AsyncThrowingStream<DraftSummary?, Error>
    func draftSkeleton(_ input: DraftInput) async throws -> DraftFields?
    func sentConversation(_ draft: DraftKey) async throws -> ThreadKey?
    func reviewQueue(_ account: AccountID?) -> AsyncThrowingStream<[DraftSummary], Error>
    func connectivity() -> AsyncStream<[AccountID: ConnectivityState]>
    func syncProgress() -> AsyncStream<[AccountID: String]>
    func pendingChanges() -> AsyncStream<[AccountID: Int]>
    func smartSearchStatus() -> AsyncStream<SmartSearchStatus>
    func contactSuggestions(_ account: AccountID, prefix: String, limit: Int) async throws -> [EmailAddress]
    func recentThreads(involving email: String, account: AccountID, limit: Int) async throws -> [ThreadRow]
    func snippets(_ account: AccountID?) -> AsyncThrowingStream<[SnippetInfo], Error>
    func reminders(_ account: AccountID?) -> AsyncThrowingStream<[ReminderItem], Error>
    func failedOperations(_ account: AccountID?) -> AsyncThrowingStream<[FailedOperationInfo], Error>
    func unsubscribeInfo(_ key: MessageKey) async throws -> UnsubscribeInfo?
    func listID(_ key: MessageKey) async throws -> String?
    func diagnosticsSnapshot() async throws -> DiagnosticsSnapshot
    func localThread(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRow?
    func searchOnce(_ query: String, semanticText: String?, accounts: [AccountID]?, limit: Int) async throws
        -> SearchResultsInfo
    func remoteSearch(gmailQuery: String, account: AccountID, maxResults: Int) async throws -> [ThreadKey]
    func refresh(_ account: AccountID) async throws
    func superhumanReminderEmails(_ account: AccountID, limit: Int) async throws -> [SuperhumanReminderEmail]
    func conversationDebugFacts(_ key: ThreadKey) async throws -> ConversationDebugStoreFacts?
}

extension MailDataSource {
    public func connectivity() -> AsyncStream<[AccountID: ConnectivityState]> {
        AsyncStream { $0.finish() }
    }

    public func syncProgress() -> AsyncStream<[AccountID: String]> {
        AsyncStream { $0.finish() }
    }

    public func pendingChanges() -> AsyncStream<[AccountID: Int]> {
        AsyncStream { $0.finish() }
    }

    public func smartSearchStatus() -> AsyncStream<SmartSearchStatus> {
        AsyncStream { $0.finish() }
    }

    public func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error> { unsupportedStream("labels") }
    public func splits(_ account: AccountID) -> AsyncThrowingStream<[SplitInfo], Error> { unsupportedStream("splits") }
    public func counts(_ account: AccountID) -> AsyncThrowingStream<MailboxCountsInfo, Error> { unsupportedStream("counts") }
    public func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                           limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        throw MailPortError.unsupported("threadPage")
    }
    public func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        throw MailPortError.unsupported("attachmentData")
    }
    public func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error> {
        unsupportedStream("search")
    }
    public func searchGmail(_ query: String, account: AccountID) async throws -> Int {
        throw MailPortError.unsupported("searchGmail")
    }
    public func drafts(_ account: AccountID?, review: Bool) -> AsyncThrowingStream<[DraftSummary], Error> {
        unsupportedStream("drafts")
    }
    public func draft(_ key: DraftKey) -> AsyncThrowingStream<DraftSummary?, Error> { unsupportedStream("draft") }
    public func draftSkeleton(_ input: DraftInput) async throws -> DraftFields? {
        throw MailPortError.unsupported("draftSkeleton")
    }
    public func sentConversation(_ draft: DraftKey) async throws -> ThreadKey? {
        throw MailPortError.unsupported("sentConversation")
    }
    public func reviewQueue(_ account: AccountID?) -> AsyncThrowingStream<[DraftSummary], Error> {
        unsupportedStream("reviewQueue")
    }
    public func contactSuggestions(_ account: AccountID, prefix: String, limit: Int) async throws -> [EmailAddress] {
        throw MailPortError.unsupported("contactSuggestions")
    }
    public func snippets(_ account: AccountID?) -> AsyncThrowingStream<[SnippetInfo], Error> { unsupportedStream("snippets") }
    public func reminders(_ account: AccountID?) -> AsyncThrowingStream<[ReminderItem], Error> {
        unsupportedStream("reminders")
    }
    public func failedOperations(_ account: AccountID?) -> AsyncThrowingStream<[FailedOperationInfo], Error> {
        unsupportedStream("failedOperations")
    }
    public func unsubscribeInfo(_ key: MessageKey) async throws -> UnsubscribeInfo? {
        throw MailPortError.unsupported("unsubscribeInfo")
    }
    public func listID(_ key: MessageKey) async throws -> String? { nil }
    public func diagnosticsSnapshot() async throws -> DiagnosticsSnapshot {
        throw MailPortError.unsupported("diagnosticsSnapshot")
    }
    public func localThread(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadRow? {
        throw MailPortError.unsupported("localThread")
    }

    public func searchOnce(_ query: String, semanticText: String?, accounts: [AccountID]?,
                           limit: Int) async throws -> SearchResultsInfo {
        for try await results in search(query, accounts: accounts, limit: limit) { return results }
        throw MailPortError.unavailable("search")
    }

    public func remoteSearch(gmailQuery: String, account: AccountID, maxResults: Int) async throws -> [ThreadKey] {
        throw MailPortError.unsupported("remoteSearch")
    }

    public func refresh(_ account: AccountID) async throws {
        throw MailPortError.unsupported("refresh")
    }

    public func superhumanReminderEmails(_ account: AccountID, limit: Int) async throws -> [SuperhumanReminderEmail] {
        throw MailPortError.unsupported("superhumanReminderEmails")
    }

    public func conversationDebugFacts(_ key: ThreadKey) async throws -> ConversationDebugStoreFacts? { nil }

    public func storedBody(_ key: MessageKey) async throws -> MessageContent? { nil }
}

func unsupportedStream<T>(_ member: String) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { $0.finish(throwing: MailPortError.unsupported(member)) }
}
