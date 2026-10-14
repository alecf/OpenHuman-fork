import Foundation
import OpenHumanCore

public struct GmailProfile: Codable, Sendable, Hashable {
    public var emailAddress: String; public var messagesTotal: Int?; public var threadsTotal: Int?; public var historyId: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        emailAddress: String,
        messagesTotal: Int? = nil,
        threadsTotal: Int? = nil,
        historyId: String
    ) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
    // end generated-init
}

public struct GmailHeader: Codable, Sendable, Hashable {
    public var name: String; public var value: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        name: String,
        value: String
    ) {
        self.name = name
        self.value = value
    }
    // end generated-init
}

public struct GmailMessagePartBody: Codable, Sendable, Hashable {
    public var attachmentId: String?; public var size: Int?; public var data: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        attachmentId: String? = nil,
        size: Int? = nil,
        data: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.size = size
        self.data = data
    }
    // end generated-init
}

public struct GmailMessagePart: Codable, Sendable, Hashable {
    public var partId: String?; public var mimeType: String?; public var filename: String?
    public var headers: [GmailHeader]?; public var body: GmailMessagePartBody?; public var parts: [GmailMessagePart]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        partId: String? = nil,
        mimeType: String? = nil,
        filename: String? = nil,
        headers: [GmailHeader]? = nil,
        body: GmailMessagePartBody? = nil,
        parts: [GmailMessagePart]? = nil
    ) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }
    // end generated-init
}

public struct GmailMessage: Codable, Sendable, Hashable {
    public var id: String; public var threadId: String?
    public var labelIds: [String]?; public var snippet: String?
    public var historyId: String?; public var internalDate: String?; public var sizeEstimate: Int?
    public var payload: GmailMessagePart?; public var raw: String?
    public var historyIDValue: HistoryID? { historyId.flatMap { UInt64($0) }.map { HistoryID($0) } }
    public var internalDateValue: Date? { internalDate.flatMap { Int64($0) }.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        threadId: String? = nil,
        labelIds: [String]? = nil,
        snippet: String? = nil,
        historyId: String? = nil,
        internalDate: String? = nil,
        sizeEstimate: Int? = nil,
        payload: GmailMessagePart? = nil,
        raw: String? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.sizeEstimate = sizeEstimate
        self.payload = payload
        self.raw = raw
    }
    // end generated-init
}

public struct GmailThread: Codable, Sendable, Hashable {
    public var id: String; public var snippet: String?; public var historyId: String?; public var messages: [GmailMessage]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        snippet: String? = nil,
        historyId: String? = nil,
        messages: [GmailMessage]? = nil
    ) {
        self.id = id
        self.snippet = snippet
        self.historyId = historyId
        self.messages = messages
    }
    // end generated-init
}

public struct GmailLabelColor: Codable, Sendable, Hashable {
    public var textColor: String?; public var backgroundColor: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        textColor: String? = nil,
        backgroundColor: String? = nil
    ) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
    // end generated-init
}
public struct GmailLabel: Codable, Sendable, Hashable {
    public var id: String; public var name: String; public var type: String?
    public var messageListVisibility: String?; public var labelListVisibility: String?
    public var messagesTotal: Int?; public var messagesUnread: Int?; public var threadsTotal: Int?; public var threadsUnread: Int?
    public var color: GmailLabelColor?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        name: String,
        type: String? = nil,
        messageListVisibility: String? = nil,
        labelListVisibility: String? = nil,
        messagesTotal: Int? = nil,
        messagesUnread: Int? = nil,
        threadsTotal: Int? = nil,
        threadsUnread: Int? = nil,
        color: GmailLabelColor? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.messageListVisibility = messageListVisibility
        self.labelListVisibility = labelListVisibility
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
        self.color = color
    }
    // end generated-init
}

public struct GmailDraft: Codable, Sendable, Hashable {
    public var id: String; public var message: GmailMessage?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        message: GmailMessage? = nil
    ) {
        self.id = id
        self.message = message
    }
    // end generated-init
}

public struct GmailHistoryMessageRef: Codable, Sendable, Hashable {
    public var message: GmailMessage

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: GmailMessage
    ) {
        self.message = message
    }
    // end generated-init
}
public struct GmailHistoryLabelChange: Codable, Sendable, Hashable {
    public var message: GmailMessage; public var labelIds: [String]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: GmailMessage,
        labelIds: [String]
    ) {
        self.message = message
        self.labelIds = labelIds
    }
    // end generated-init
}
public struct GmailHistoryRecord: Codable, Sendable, Hashable {
    public var id: String
    public var messages: [GmailMessage]?
    public var messagesAdded: [GmailHistoryMessageRef]?
    public var messagesDeleted: [GmailHistoryMessageRef]?
    public var labelsAdded: [GmailHistoryLabelChange]?
    public var labelsRemoved: [GmailHistoryLabelChange]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        id: String,
        messages: [GmailMessage]? = nil,
        messagesAdded: [GmailHistoryMessageRef]? = nil,
        messagesDeleted: [GmailHistoryMessageRef]? = nil,
        labelsAdded: [GmailHistoryLabelChange]? = nil,
        labelsRemoved: [GmailHistoryLabelChange]? = nil
    ) {
        self.id = id
        self.messages = messages
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
    // end generated-init
}

public struct GmailListThreadsResponse: Codable, Sendable, Hashable {
    public var threads: [GmailThread]?; public var nextPageToken: String?; public var resultSizeEstimate: Int?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        threads: [GmailThread]? = nil,
        nextPageToken: String? = nil,
        resultSizeEstimate: Int? = nil
    ) {
        self.threads = threads
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
    // end generated-init
}
public struct GmailListMessagesResponse: Codable, Sendable, Hashable {
    public var messages: [GmailMessage]?; public var nextPageToken: String?; public var resultSizeEstimate: Int?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        messages: [GmailMessage]? = nil,
        nextPageToken: String? = nil,
        resultSizeEstimate: Int? = nil
    ) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
    // end generated-init
}
public struct GmailListDraftsResponse: Codable, Sendable, Hashable {
    public var drafts: [GmailDraft]?; public var nextPageToken: String?; public var resultSizeEstimate: Int?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        drafts: [GmailDraft]? = nil,
        nextPageToken: String? = nil,
        resultSizeEstimate: Int? = nil
    ) {
        self.drafts = drafts
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
    // end generated-init
}
public struct GmailListHistoryResponse: Codable, Sendable, Hashable {
    public var history: [GmailHistoryRecord]?; public var nextPageToken: String?; public var historyId: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        history: [GmailHistoryRecord]? = nil,
        nextPageToken: String? = nil,
        historyId: String
    ) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
    // end generated-init
}
public struct GmailListLabelsResponse: Codable, Sendable, Hashable {
    public var labels: [GmailLabel]?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        labels: [GmailLabel]? = nil
    ) {
        self.labels = labels
    }
    // end generated-init
}

public struct GmailSendAs: Codable, Sendable, Hashable {
    public var sendAsEmail: String; public var displayName: String?; public var replyToAddress: String?
    public var signature: String?; public var isPrimary: Bool?; public var isDefault: Bool?; public var verificationStatus: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        sendAsEmail: String,
        displayName: String? = nil,
        replyToAddress: String? = nil,
        signature: String? = nil,
        isPrimary: Bool? = nil,
        isDefault: Bool? = nil,
        verificationStatus: String? = nil
    ) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.replyToAddress = replyToAddress
        self.signature = signature
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.verificationStatus = verificationStatus
    }
    // end generated-init
}
