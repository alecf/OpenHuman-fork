import Foundation
import OpenHumanAI

public struct EvalEmail: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let category: TriageCategory
    public let priority: Int
    public let subject: String
    public let from: String
    public let body: String
    public let tags: [String]

    public var isInjection: Bool { tags.contains("injection") }

    public var thread: AIThreadInput {
        AIThreadInput(
            threadKey: "eval-\(id)", subject: subject,
            messages: [
                AIMessageInput(
                    messageKey: "eval-\(id)-m1", from: from, date: Date(timeIntervalSince1970: 1_790_000_000), bodyText: body,
                    subject: subject)
            ])
    }

    public var classificationInput: ClassificationInput { ClassificationInput.make(from: thread) }
}

public enum EvalCorpus {
    public enum LoadError: Error, Equatable {
        case missingResource
        case badLine(Int)
    }

    public static func load() throws -> [EvalEmail] {
        guard let url = Bundle.module.url(forResource: "corpus", withExtension: "jsonl") else { throw LoadError.missingResource }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    public static func parse(_ jsonl: String) throws -> [EvalEmail] {
        let decoder = JSONDecoder()
        var emails: [EvalEmail] = []
        for (index, line) in jsonl.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let email = try? decoder.decode(EvalEmail.self, from: Data(line.utf8)) else { throw LoadError.badLine(index + 1) }
            emails.append(email)
        }
        return emails
    }
}
