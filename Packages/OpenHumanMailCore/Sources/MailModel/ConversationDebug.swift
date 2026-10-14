import Foundation

public struct ConversationDebugMimePart: Sendable, Hashable, Codable {
    public var contentType: String
    public var size: Int
    public var fileExtension: String?

    public init(contentType: String, size: Int, fileExtension: String? = nil) {
        self.contentType = contentType
        self.size = size
        self.fileExtension = fileExtension
    }
}

public struct ConversationDebugStoreMessage: Sendable, Hashable {
    public var message: MessageKey
    public var labelIDs: [String]
    public var bodyState: String?
    public var sizeBytes: Int?
    public var headerNames: [String]?
    public var mimeParts: [ConversationDebugMimePart]?
    public var isFromMe: Bool?
    public var hasAttachments: Bool?
    public var horizon: String?
    public var aiCache: [String: String]?

    public init(message: MessageKey, labelIDs: [String] = [], bodyState: String? = nil, sizeBytes: Int? = nil,
                headerNames: [String]? = nil, mimeParts: [ConversationDebugMimePart]? = nil, isFromMe: Bool? = nil,
                hasAttachments: Bool? = nil, horizon: String? = nil, aiCache: [String: String]? = nil) {
        self.message = message
        self.labelIDs = labelIDs
        self.bodyState = bodyState
        self.sizeBytes = sizeBytes
        self.headerNames = headerNames
        self.mimeParts = mimeParts
        self.isFromMe = isFromMe
        self.hasAttachments = hasAttachments
        self.horizon = horizon
        self.aiCache = aiCache
    }
}

public struct ConversationDebugStoreFacts: Sendable, Hashable {
    public var messages: [ConversationDebugStoreMessage]
    public var aiCache: [String: String]?

    public init(messages: [ConversationDebugStoreMessage], aiCache: [String: String]? = nil) {
        self.messages = messages
        self.aiCache = aiCache
    }
}
