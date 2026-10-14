import Foundation
import OpenHumanCore

public struct ParsedMessage: Sendable, Hashable {
    public var headers: MIMEHeaders
    public var subject: String
    public var from: EmailAddress?; public var to: [EmailAddress]; public var cc: [EmailAddress]
    public var bcc: [EmailAddress]; public var replyTo: [EmailAddress]
    public var date: Date?; public var messageID: String?; public var inReplyTo: String?; public var references: [String]
    public var listID: String?; public var listUnsubscribe: String?; public var listUnsubscribePost: String?
    public var htmlBody: String?
    public var textBody: String?
    public var attachments: [ParsedAttachment]
    public var calendarParts: [String]
    public var warnings: [String]
    public var textFormat: TextPartFormat = .fixed

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        headers: MIMEHeaders,
        subject: String,
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        replyTo: [EmailAddress],
        date: Date? = nil,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String],
        listID: String? = nil,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        htmlBody: String? = nil,
        textBody: String? = nil,
        attachments: [ParsedAttachment],
        calendarParts: [String],
        warnings: [String],
        textFormat: TextPartFormat = .fixed
    ) {
        self.headers = headers
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.listID = listID
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.calendarParts = calendarParts
        self.warnings = warnings
        self.textFormat = textFormat
    }
    // end generated-init
}

public struct ParsedAttachment: Sendable, Hashable {
    public var partID: String; public var filename: String; public var mimeType: String; public var size: Int
    public var contentID: String?; public var isInline: Bool
    public var gmailAttachmentID: String?
    public var inlineData: Data?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        partID: String,
        filename: String,
        mimeType: String,
        size: Int,
        contentID: String? = nil,
        isInline: Bool,
        gmailAttachmentID: String? = nil,
        inlineData: Data? = nil
    ) {
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.gmailAttachmentID = gmailAttachmentID
        self.inlineData = inlineData
    }
    // end generated-init
}

public struct MIMEHeaders: Sendable, Hashable {
    public var fields: [MIMEHeaderField]

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        fields: [MIMEHeaderField]
    ) {
        self.fields = fields
    }
    // end generated-init
}

public struct GmailPayloadPart: Sendable, Hashable {
    public var partID: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [MIMEHeaderField]
    public var attachmentID: String?
    public var size: Int?
    public var data: String?
    public var parts: [GmailPayloadPart]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        partID: String? = nil,
        mimeType: String? = nil,
        filename: String? = nil,
        headers: [MIMEHeaderField],
        attachmentID: String? = nil,
        size: Int? = nil,
        data: String? = nil,
        parts: [GmailPayloadPart]
    ) {
        self.partID = partID
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.attachmentID = attachmentID
        self.size = size
        self.data = data
        self.parts = parts
    }
    // end generated-init
}

public enum MIMEError: Error, Equatable, Sendable {
    case invalidHeader(String)
    case tooLarge(bytes: Int)
    case missingBody
    case malformed(String)
}

public struct OutgoingAttachment: Sendable, Hashable {
    public var filename: String; public var mimeType: String; public var data: Data
    public var contentID: String?; public var isInline: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        filename: String,
        mimeType: String,
        data: Data,
        contentID: String? = nil,
        isInline: Bool
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
        self.isInline = isInline
    }
    // end generated-init
}

public enum TextPartFormat: Sendable, Hashable, Codable {
    case fixed
    case flowed(delSp: Bool)
}

public struct OutgoingMessage: Sendable, Hashable {
    public var from: EmailAddress
    public var to: [EmailAddress]; public var cc: [EmailAddress]; public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var subject: String
    public var htmlBody: String?; public var textBody: String?
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?; public var references: [String]
    public var messageID: String
    public var date: Date
    public var extraHeaders: [MIMEHeaderField]
    public var textFormat: TextPartFormat = .fixed

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress],
        bcc: [EmailAddress],
        replyTo: [EmailAddress],
        subject: String,
        htmlBody: String? = nil,
        textBody: String? = nil,
        attachments: [OutgoingAttachment],
        inReplyTo: String? = nil,
        references: [String],
        messageID: String,
        date: Date,
        extraHeaders: [MIMEHeaderField],
        textFormat: TextPartFormat = .fixed
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.messageID = messageID
        self.date = date
        self.extraHeaders = extraHeaders
        self.textFormat = textFormat
    }
    // end generated-init
}
public struct MIMEHeaderField: Sendable, Hashable {
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

public enum BccHandling: Sendable {
    case includeForGmailSubmission
    case strip
}

public struct ReplyContext: Sendable, Hashable {
    public var messageID: String?; public var references: [String]; public var inReplyTo: String?
    public var subject: String; public var from: EmailAddress?; public var to: [EmailAddress]; public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]; public var date: Date; public var htmlBody: String?; public var textBody: String?
    public var gmailThreadID: String

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        messageID: String? = nil,
        references: [String],
        inReplyTo: String? = nil,
        subject: String,
        from: EmailAddress? = nil,
        to: [EmailAddress],
        cc: [EmailAddress],
        replyTo: [EmailAddress],
        date: Date,
        htmlBody: String? = nil,
        textBody: String? = nil,
        gmailThreadID: String
    ) {
        self.messageID = messageID
        self.references = references
        self.inReplyTo = inReplyTo
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.replyTo = replyTo
        self.date = date
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.gmailThreadID = gmailThreadID
    }
    // end generated-init
}

public enum ReplyMode: Sendable { case reply, replyAll, forward }

public struct ReplySkeleton: Sendable, Hashable {
    public var to: [EmailAddress]; public var cc: [EmailAddress]; public var subject: String
    public var inReplyTo: String?; public var references: [String]
    public var quotedHTML: String; public var quotedText: String
    public var gmailThreadID: String?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        to: [EmailAddress],
        cc: [EmailAddress],
        subject: String,
        inReplyTo: String? = nil,
        references: [String],
        quotedHTML: String,
        quotedText: String,
        gmailThreadID: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.inReplyTo = inReplyTo
        self.references = references
        self.quotedHTML = quotedHTML
        self.quotedText = quotedText
        self.gmailThreadID = gmailThreadID
    }
    // end generated-init
}
