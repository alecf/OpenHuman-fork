import Foundation
import OpenHumanCore

public enum MessageFormat: String, Sendable { case minimal, metadata, full, raw }

public let standardMetadataHeaders = ["From","To","Cc","Bcc","Reply-To","Subject","Date",
    "Message-ID","In-Reply-To","References","List-Id","List-Unsubscribe","List-Unsubscribe-Post",
    "Content-Type","X-OpenHuman-Origin"]

public struct ListQuery: Sendable, Hashable {
    public var labelIDs: [String] = []
    public var q: String? = nil
    public var pageToken: String? = nil
    public var maxResults: Int = 100
    public var includeSpamTrash: Bool = false

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        labelIDs: [String] = [],
        q: String? = nil,
        pageToken: String? = nil,
        maxResults: Int = 100,
        includeSpamTrash: Bool = false
    ) {
        self.labelIDs = labelIDs
        self.q = q
        self.pageToken = pageToken
        self.maxResults = maxResults
        self.includeSpamTrash = includeSpamTrash
    }
    // end generated-init
}

public enum HistoryType: String, Sendable { case messageAdded, messageDeleted, labelAdded, labelRemoved }

public struct BatchItemResult<T: Sendable>: Sendable {
    public var id: String; public var result: Result<T, GmailError>

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        result: Result<T, GmailError>
    ) {
        self.id = id
        self.result = result
    }
    // end generated-init
}

public protocol GmailAPI: Sendable {
    var accountEmail: String { get }

    func getProfile(priority: RequestPriority) async throws -> GmailProfile
    func listSendAs() async throws -> [GmailSendAs]

    func listLabels() async throws -> [GmailLabel]
    func getLabel(id: String) async throws -> GmailLabel
    func createLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) async throws -> GmailLabel

    func listThreads(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListThreadsResponse
    func getThread(id: String, format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> GmailThread
    func getThreads(ids: [String], format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> [BatchItemResult<GmailThread>]
    func trashThread(id: String) async throws -> GmailThread
    func untrashThread(id: String) async throws -> GmailThread

    func listMessages(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListMessagesResponse
    func getMessage(id: String, format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> GmailMessage
    func getMessages(ids: [String], format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> [BatchItemResult<GmailMessage>]
    func getAttachment(messageID: String, attachmentID: String) async throws -> Data
    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws
    func modifyMessage(id: String, add: [String], remove: [String]) async throws -> GmailMessage
    func trashMessage(id: String) async throws -> GmailMessage
    func untrashMessage(id: String) async throws -> GmailMessage
    func sendMessage(rawRFC822: Data, threadID: String?) async throws -> GmailMessage

    func listDrafts(pageToken: String?, q: String?, maxResults: Int) async throws -> GmailListDraftsResponse
    func getDraft(id: String, format: MessageFormat) async throws -> GmailDraft
    func createDraft(rawRFC822: Data, threadID: String?) async throws -> GmailDraft
    func updateDraft(id: String, rawRFC822: Data, threadID: String?) async throws -> GmailDraft
    func deleteDraft(id: String) async throws
    func sendDraft(id: String) async throws -> GmailMessage

    func listHistory(startHistoryID: HistoryID, pageToken: String?, types: [HistoryType],
                     labelID: String?, maxResults: Int, priority: RequestPriority) async throws -> GmailListHistoryResponse

    func insertMessage(rawRFC822: Data, labelIDs: [String]) async throws -> GmailMessage
}

public struct GmailClientConfig: Sendable {
    public var unitsPerMinute: Int = 6000
    public var batchSize: Int = 25
    public var maxConcurrentRequests: Int = 8
    public var retryBackground: RetryPolicy = .background
    public var retryInteractive: RetryPolicy = .interactive
    public var userAgent: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        unitsPerMinute: Int = 6000,
        batchSize: Int = 25,
        maxConcurrentRequests: Int = 8,
        retryBackground: RetryPolicy = .background,
        retryInteractive: RetryPolicy = .interactive,
        userAgent: String
    ) {
        self.unitsPerMinute = unitsPerMinute
        self.batchSize = batchSize
        self.maxConcurrentRequests = maxConcurrentRequests
        self.retryBackground = retryBackground
        self.retryInteractive = retryInteractive
        self.userAgent = userAgent
    }
    // end generated-init
}

public protocol GmailClientFactory: Sendable {
    func client(for accountEmail: String) throws -> GmailAPI
}
