import Foundation
import OpenHumanCore

public struct IndexableMessage: Hashable, Sendable {
    public var message: MessageRowID
    public var account: AccountID
    public var gmailMessageID: GmailMessageID
    public var thread: ThreadRowID
    public var internalDate: Date
    public var bodyState: BodyState
    public var isDraft: Bool
    public var inSpam: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: MessageRowID,
        account: AccountID,
        gmailMessageID: GmailMessageID,
        thread: ThreadRowID,
        internalDate: Date,
        bodyState: BodyState,
        isDraft: Bool,
        inSpam: Bool
    ) {
        self.message = message
        self.account = account
        self.gmailMessageID = gmailMessageID
        self.thread = thread
        self.internalDate = internalDate
        self.bodyState = bodyState
        self.isDraft = isDraft
        self.inSpam = inSpam
    }
    // end generated-init
}

public struct IndexableDocument: Hashable, Sendable {
    public var message: MessageRowID
    public var subject: String
    public var fromName: String?
    public var body: String
    public var attachmentNames: [String]
    public var hasStoredBody: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: MessageRowID,
        subject: String,
        fromName: String? = nil,
        body: String,
        attachmentNames: [String],
        hasStoredBody: Bool
    ) {
        self.message = message
        self.subject = subject
        self.fromName = fromName
        self.body = body
        self.attachmentNames = attachmentNames
        self.hasStoredBody = hasStoredBody
    }
    // end generated-init
}

public enum BodyDownloadStatus: String, Hashable, Sendable { case downloading, complete, capped, off }

public protocol SemanticIndexReading: Sendable {
    func storeEpoch() throws -> String
    func indexableMessages(afterMessage: MessageRowID?, limit: Int) throws -> [IndexableMessage]
    func indexableMessages(_ ids: [MessageRowID]) throws -> [IndexableMessage]
    func messageIDsAwaitingBodies(account: AccountID) throws -> [MessageRowID]
    func indexableDocuments(_ ids: [MessageRowID]) throws -> [IndexableDocument]
    func messageIdentities(_ ids: [MessageRowID]) throws -> [MessageRowID: GmailMessageID]
    func bodyDownloadStatus(account: AccountID) throws -> BodyDownloadStatus
    func indexableCount(account: AccountID) throws -> Int
}
