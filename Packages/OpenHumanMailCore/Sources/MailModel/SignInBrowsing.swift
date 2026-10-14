import Foundation

public struct PendingSignIn: Identifiable, Sendable, Hashable {
    public enum Purpose: Sendable, Hashable {
        case email
        case calendar
    }

    public let id: UUID
    public let url: URL
    public let account: String?
    public let purpose: Purpose
    public let openedIn: String?
    public let openFailed: Bool

    public init(id: UUID = UUID(), url: URL, account: String?, purpose: Purpose, openedIn: String? = nil,
                openFailed: Bool = false) {
        self.id = id
        self.url = url
        self.account = account
        self.purpose = purpose
        self.openedIn = openedIn
        self.openFailed = openFailed
    }
}

public struct InstalledBrowser: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let appPath: String

    public init(id: String, name: String, appPath: String) {
        self.id = id
        self.name = name
        self.appPath = appPath
    }
}

public protocol SignInBrowsing: Sendable {
    func pendingSignIns() -> AsyncStream<PendingSignIn?>
    func installedBrowsers() async -> [InstalledBrowser]
    func open(_ id: PendingSignIn.ID, in browser: InstalledBrowser.ID?) async throws
    func rememberedBrowser(for account: String?) async -> InstalledBrowser.ID?
    func cancel(_ id: PendingSignIn.ID) async
}

public struct SignInBrowserError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

@MainActor
public protocol SignInClipboard: AnyObject {
    func copy(_ text: String) -> Int
    @discardableResult
    func clear(ifUnchangedSince mark: Int) -> Bool
}
