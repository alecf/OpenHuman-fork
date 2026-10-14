import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct AIProviderConsentRequest: Identifiable, Hashable, Sendable {
    public struct AccountChoice: Identifiable, Hashable, Sendable {
        public let id: AccountID
        public let title: String
        public var onDeviceOnly: Bool
    }

    public var id: AIProviderID { providerID }
    public let providerID: AIProviderID
    public let providerName: String
    public let location: AIDataLocation
    public var accounts: [AccountChoice]
    public var paragraphsOverride: [String]? = nil

    public var title: String { String(localized: "Send email text to \(providerName)?") }

    public var paragraphs: [String] {
        if let paragraphsOverride { return paragraphsOverride }
        switch location {
        case .onDevice:
            return []
        case .appleCloud:
            return [
                String(localized: "What is sent: the text of the email or conversation you use AI on, and your instruction. Nothing else, and only when you use an AI feature."),
                String(localized: "To whom: Apple's servers (Private Cloud Compute). Apple describes how Private Cloud Compute handles data on its website; that description is Apple's. Mail has no account or key of its own there, and usage limits may apply."),
                String(localized: "Mail never uses it in the background, and never for accounts set to On-device AI only."),
                String(localized: "Turn it off any time in Settings › AI."),
            ]
        case .thirdParty(let vendor):
            return [
                String(localized: "What is sent: the text of the email or conversation you use AI on, and your instruction. Nothing else, and only when you use an AI feature."),
                String(localized: "To whom: \(vendor), through your own \(providerName) login, under your account and \(vendor)'s terms."),
                String(localized: "Mail never uses it in the background, never writes or sends mail with it, and never uses it for accounts set to On-device AI only."),
                String(localized: "Turn it off any time in Settings › AI."),
            ]
        }
    }

    public var learnMoreURL: URL? { nil }

    public var acceptTitle: String { String(localized: "Allow \(providerName)") }
    public var declineTitle: String { String(localized: "Not now") }
}
