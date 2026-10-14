import Foundation
import Observation

@MainActor @Observable
public final class SettingsNavigator {
    public private(set) var requestedPage: String?
    public private(set) var addAccountRequested = false
    public private(set) var requestedPrompt: String?
    @ObservationIgnored public var openWindow: (@MainActor () -> Void)?

    public init() {}

    public var canOpen: Bool { openWindow != nil }

    public func open(_ page: String) {
        requestedPage = page
        openWindow?()
    }

    public func addAccount() {
        addAccountRequested = true
        open(SettingsPageID.accounts.rawValue)
    }

    public func openPrompt(_ promptID: String?) {
        requestedPrompt = promptID ?? ""
        open(SettingsPageID.ai.rawValue)
    }

    public func takeRequestedPrompt() -> String? {
        guard let prompt = requestedPrompt else { return nil }
        requestedPrompt = nil
        return prompt
    }

    public func takeRequestedPage() -> String? {
        guard let page = requestedPage else { return nil }
        requestedPage = nil
        return page
    }

    public func takeAddAccountRequest() -> Bool {
        guard addAccountRequested else { return false }
        addAccountRequested = false
        return true
    }
}
