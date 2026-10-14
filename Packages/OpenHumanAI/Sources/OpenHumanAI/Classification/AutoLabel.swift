import Foundation

public enum AutoLabelCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case respond, waiting, meeting, invoice, travel, pitch, social, news, marketing

    public static let modelCategories: [AutoLabelCategory] = [
        .respond, .meeting, .invoice, .travel, .pitch, .social, .news, .marketing,
    ]

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public init?(title: String) {
        self.init(rawValue: title.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

public enum AutoLabelPrompt {
    public static let name = PromptName.autoLabel

    public static var version: Int {
        (try? PromptLibrary.standard.template(named: name.rawValue).id.version) ?? 0
    }
}

extension AIClassificationProvider {
    public func autoLabel(_ input: ClassificationInput) async throws -> AutoLabelCategory? {
        throw AIError.unavailable(.other("This classifier does not sort mail into auto labels"))
    }
}
