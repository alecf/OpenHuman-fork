import Foundation

public struct FollowUpInput: Sendable, Hashable {
    public var messageKey: String
    public var threadKey: String?
    public var subject: String
    public var from: String
    public var text: String
    public var sentAt: Date
    public var context: [AIMessageInput]
    public var accountKey: String?

    public init(messageKey: String, threadKey: String? = nil, subject: String, from: String, text: String, sentAt: Date,
                context: [AIMessageInput] = [], accountKey: String? = nil) {
        self.messageKey = messageKey
        self.threadKey = threadKey
        self.subject = subject
        self.from = from
        self.text = text
        self.sentAt = sentAt
        self.context = context
        self.accountKey = accountKey
    }
}

public struct FollowUpResult: Sendable, Hashable, Codable {
    public var needsFollowUp: Bool
    public var reason: String
    public var suggestedDays: Int?
    public var providerID: AIProviderID?
    public var fromCache: Bool

    public init(needsFollowUp: Bool, reason: String, suggestedDays: Int? = nil, providerID: AIProviderID? = nil,
                fromCache: Bool = false) {
        self.needsFollowUp = needsFollowUp
        self.reason = reason
        self.suggestedDays = suggestedDays
        self.providerID = providerID
        self.fromCache = fromCache
    }

    public static let no = FollowUpResult(needsFollowUp: false, reason: "")
}

extension OutputGuard {
    public static let followUpSchema: JSONSchema = .object(
        properties: [
            "needsFollowUp": .boolean,
            "reason": .string(maxLength: 400),
            "suggestedDays": .integer(minimum: 1, maximum: AIPolicy.followUpMaxDays),
        ],
        required: ["needsFollowUp", "reason"])

    public static func followUp(from data: Data) throws -> FollowUpResult {
        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(data)
        } catch {
            throw AIError.invalidOutput("not JSON")
        }
        guard case .object(var fields) = parsed else { throw AIError.invalidOutput("not an object") }
        if case .null? = fields["suggestedDays"] { fields["suggestedDays"] = nil }
        let value = JSONValue.object(fields)
        let errors = followUpSchema.validate(value)
        guard errors.isEmpty else { throw AIError.invalidOutput(errors.prefix(3).joined(separator: "; ")) }
        guard case .bool(let needs)? = value["needsFollowUp"] else { throw AIError.invalidOutput("needsFollowUp") }
        return FollowUpResult(needsFollowUp: needs, reason: followUpReason(value["reason"]?.stringValue ?? ""),
                              suggestedDays: value["suggestedDays"]?.integerValue)
    }

    static func followUpReason(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).prefix(AIPolicy.followUpReasonWords)
        return capCharacters(words.joined(separator: " "), maxCharacters: AIPolicy.followUpReasonCharacters)
    }
}
