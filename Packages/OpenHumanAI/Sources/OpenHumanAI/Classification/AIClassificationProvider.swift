import Foundation

public protocol AIClassificationProvider: Sendable {
    var id: AIProviderID { get }
    var displayName: String { get }
    var dataLocation: AIDataLocation { get }
    func availability() async -> AIAvailability
    func modelVersion() async -> String?
    func classify(_ input: ClassificationInput) async throws -> TriageResult
    func autoLabel(_ input: ClassificationInput) async throws -> AutoLabelCategory?
}

public struct ClassificationInput: Sendable, Hashable {
    public var threadKey: String
    public var accountKey: String?
    public var subject: UntrustedPart
    public var sender: UntrustedPart
    public var excerpt: UntrustedPart

    public init(threadKey: String, accountKey: String?, subject: UntrustedPart, sender: UntrustedPart,
                excerpt: UntrustedPart)
    {
        self.threadKey = threadKey
        self.accountKey = accountKey
        self.subject = subject
        self.sender = sender
        self.excerpt = excerpt
    }

    public var parts: [UntrustedPart] { [subject, sender, excerpt] }

    public static func make(from thread: AIThreadInput) -> ClassificationInput {
        let latest = thread.messages.last
        let messageID = latest?.messageKey ?? thread.threadKey
        return ClassificationInput(
            threadKey: thread.threadKey,
            accountKey: thread.accountKey,
            subject: UntrustedPart(
                kind: .subject, id: thread.threadKey, text: String(thread.subject.prefix(AIPolicy.subjectCharacterCap))),
            sender: UntrustedPart(
                kind: .sender, id: messageID, text: String((latest?.from ?? "").prefix(AIPolicy.senderCharacterCap))),
            excerpt: UntrustedPart(
                kind: .emailBody, id: messageID,
                text: String((latest?.bodyText ?? "").prefix(AIPolicy.classifyExcerptCharacters)), date: latest?.date)
        )
    }
}
