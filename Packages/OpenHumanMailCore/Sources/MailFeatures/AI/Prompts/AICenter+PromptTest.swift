import Foundation
import MailModel
import OpenHumanAI

public struct PromptTestResult: Equatable, Sendable {
    public var output: String
    public var promptIdentity: String
    public var providerName: String?
    public var subject: String

    public init(output: String, promptIdentity: String, providerName: String?, subject: String) {
        self.output = output
        self.promptIdentity = promptIdentity
        self.providerName = providerName
        self.subject = subject
    }
}

public enum PromptTestError: Error, Equatable, Sendable {
    case noConversation
    case notTestable
    case failed(String)
}

extension AICenter {
    public var promptTestThread: ThreadKey? { environment?.router.reader?.thread }

    public func testPrompt(_ info: PromptInfo, draft: String?, on thread: ThreadKey) async throws -> PromptTestResult {
        guard let test = info.threadTest else { throw PromptTestError.notTestable }
        guard let context = await context(for: thread, trigger: .user) else { throw PromptTestError.noConversation }
        let input = context.input
        let features: any AIFeatures = registry.map { registry in
            let box = settingsBox
            return DefaultAIFeatures(registry: registry, settings: { box.current }, cache: InMemoryAIResultCache(),
                                     activity: activity)
        } ?? self.features
        let drafts = draft.map { [info.id: $0] } ?? [:]
        let userName = userName(thread.account)
        do {
            return try await PromptLibraryProvider.withDrafts(drafts) {
                let identity = (try? PromptLibraryProvider.shared.current.template(named: info.id).identity) ?? info.id
                let (output, provider) = try await Self.run(test, input: input, userName: userName, features: features,
                                                            center: self)
                return PromptTestResult(output: output, promptIdentity: identity, providerName: provider,
                                        subject: input.subject)
            }
        } catch let error as PromptTestError {
            throw error
        } catch {
            throw PromptTestError.failed(AIWording.failure(error))
        }
    }

    private static func run(_ test: PromptInfo.ThreadTest, input: AIThreadInput, userName: String,
                            features: any AIFeatures, center: AICenter) async throws -> (String, String?) {
        switch test {
        case .summary:
            var text = ""
            var provider: String?
            for try await event in features.summarize(input) {
                switch event {
                case .started(let provenance): provider = provenance.providerName
                case .textDelta(let delta): text += delta
                case .completed: break
                }
            }
            return (text, provider)
        case .line:
            let line = try await features.summarizeLine(input)
            return (line.text, await providerName(.summarize, input: input, features: features))
        case .replies:
            let result = try await features.replyOptionsResult(input, userName: userName)
            let text = result.options.map { $0.label + "\n" + $0.body }.joined(separator: "\n\n")
            return (text, result.provenance.providerName)
        case .triage:
            let result = try await features.classify(input)
            let reason = result.reason.isEmpty ? "" : " · " + result.reason
            return ("\(result.category.rawValue) · priority \(result.priority)\(reason)",
                    await providerName(.classify, input: input, features: features))
        case .autoLabel:
            guard let classifier = await center.onDeviceClassifier() else {
                throw PromptTestError.failed(String(localized: "No classifier on this Mac is ready."))
            }
            let category = try await classifier.autoLabel(classificationInput(input))
            return (category?.title ?? String(localized: "No label"), classifier.displayName)
        }
    }

    private static func providerName(_ feature: AIFeature, input: AIThreadInput, features: any AIFeatures) async
        -> String?
    {
        await features.status(for: feature, accountKey: input.accountKey).providerName
    }

    private func onDeviceClassifier() async -> (any AIClassificationProvider)? {
        guard let registry else { return nil }
        for classifier in ClassifierSelection.ordered(registry.classifiers, preference: settings.classifier)
        where classifier.dataLocation == .onDevice {
            if case .available = await classifier.availability() { return classifier }
        }
        return nil
    }

    static func classificationInput(_ input: AIThreadInput) -> ClassificationInput {
        let latest = input.messages.last
        let messageKey = latest?.messageKey ?? input.threadKey
        return ClassificationInput(
            threadKey: input.threadKey, accountKey: nil,
            subject: UntrustedPart(kind: .subject, id: input.threadKey,
                                   text: String(input.subject.prefix(AIPolicy.subjectCharacterCap))),
            sender: UntrustedPart(kind: .sender, id: messageKey,
                                  text: String((latest?.from ?? "").prefix(AIPolicy.senderCharacterCap))),
            excerpt: UntrustedPart(kind: .emailBody, id: messageKey,
                                   text: String((latest?.bodyText ?? "").prefix(AIPolicy.classifyExcerptCharacters)),
                                   date: latest?.date))
    }
}
