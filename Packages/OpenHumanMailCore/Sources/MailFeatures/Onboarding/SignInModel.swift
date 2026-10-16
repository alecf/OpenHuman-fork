import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
public protocol TextPasteboard: AnyObject {
    func copy(_ text: String)
}

public struct SignInScreen: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case signIn
        case setUpGoogle
        case importClientFile
        case cancel
    }

    public let appName: String
    public let sentence: String
    public let action: Action?

    public var actionTitle: String? {
        switch action {
        case .signIn?: "Sign in with Google"
        case .setUpGoogle?: "Set up Google"
        case .importClientFile?: "Import client file…"
        case .cancel?: "Cancel"
        case nil: nil
        }
    }

    public var buttons: [String] { actionTitle.map { [$0] } ?? [] }
}

public enum SignInMoreOption: String, CaseIterable, Sendable {
    case specificAccount
    case anotherDevice
    case ownClient
    case clientChoice
    case haveClientFile
    case clientFileHelp
    case whatMailAsksFor
}

@MainActor
@Observable
public final class SignInModel {
    public enum Phase: Equatable, Sendable {
        case checking
        case needsClient
        case ready
        case signingIn
        case signedIn(AccountID)
        case remotePreparing
        case remotePaste
        case remoteCompleting
    }

    public private(set) var phase: Phase = .checking
    public private(set) var clientStatus: OAuthClientStatus?
    public private(set) var clients: [OAuthClientSummary] = []
    public private(set) var errorMessage: String?
    public private(set) var clientNote: String?
    public let notice: String?
    public var loginHint: String
    public private(set) var remoteURL: URL?
    public var pastedAddress: String = ""

    public private(set) var remoteAddressCopied = false

    public let clientGuide = GoogleClientGuide()
    public private(set) var showsClientGuide = false
    public var showsAccountField: Bool
    @ObservationIgnored public var pasteboard: (any TextPasteboard)?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    @ObservationIgnored public var onSignedIn: (@MainActor (AccountID) -> Void)?
    @ObservationIgnored private let accounts: any AccountManaging
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let remoteTimeout: Duration

    public init(accounts: any AccountManaging, loginHint: String = "", notice: String? = nil,
                remoteTimeout: Duration = .seconds(600)) {
        self.remoteTimeout = remoteTimeout
        self.accounts = accounts
        self.loginHint = loginHint
        self.notice = notice
        self.showsAccountField = !loginHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let appName = OHIdentifiers.productName
    public static let readySentence = "Sign in to use your Gmail on this Mac."
    public static let needsClientSentence = "Set up Google once to use Gmail here."
    public static let importFullFileSentence = "Import the full Google client file to sign in."
    public static let environmentWithoutSecretSentence = "Use the full client file, then open Mail again."
    public static let waitingSentence = "Finish in your browser; Google shows exactly what Mail asks for."
    public static let checkingSentence = readySentence
    public static let remoteSentence = "Sign in from another device."
    public static let signedInSentence = "Signed in."
    public static let keychainSyncNote = "Your sign-in is kept in your Keychain and syncs through iCloud Keychain if you "
        + "have it turned on."
    public static let keychainLocalNote = "Your sign-in is kept in this Mac's Keychain."

    public static func keychainNote(syncs: Bool) -> String { syncs ? Self.keychainSyncNote : Self.keychainLocalNote }

    public private(set) var syncsThroughICloudKeychain = false
    public var keychainNote: String { Self.keychainNote(syncs: syncsThroughICloudKeychain) }

    public var showsKeychainNote: Bool {
        switch screen.action {
        case .signIn?, .cancel?: true
        case .setUpGoogle?, .importClientFile?, nil: false
        }
    }

    public var screen: SignInScreen {
        let main = screenParts
        return SignInScreen(appName: Self.appName, sentence: main.sentence, action: main.action)
    }

    private var screenParts: (sentence: String, action: SignInScreen.Action?) {
        switch phase {
        case .checking:
            return (Self.checkingSentence, .signIn)
        case .needsClient:
            return (Self.needsClientSentence, .setUpGoogle)
        case .ready:
            if case .configuredWithoutSecret(source: .environment) = clientStatus {
                return (Self.environmentWithoutSecretSentence, nil)
            }
            if clientLacksSecret { return (Self.importFullFileSentence, .importClientFile) }
            return (notice ?? Self.readySentence, .signIn)
        case .signingIn:
            return (Self.waitingSentence, .cancel)
        case .remotePreparing, .remotePaste, .remoteCompleting:
            return (Self.remoteSentence, nil)
        case .signedIn:
            return (Self.signedInSentence, nil)
        }
    }

    public private(set) var showsMoreOptions = false
    public private(set) var showsAccessInfo = false

    public private(set) var showsOwnClient = false

    public func toggleMoreOptions() { showsMoreOptions.toggle() }
    public func toggleAccessInfo() { showsAccessInfo.toggle() }
    public func toggleOwnClient() { showsOwnClient.toggle() }

    public var moreOptions: [SignInMoreOption] {
        switch phase {
        case .needsClient:
            return canImportClient ? [.haveClientFile] : []
        case .ready:
            var options: [SignInMoreOption] = []
            if canSignIn {
                options.append(.specificAccount)
                if canSignInFromAnotherDevice { options.append(.anotherDevice) }
            }
            if canImportClient { options.append(.clientFileHelp) }
            if offersOwnClient {
                options.append(.ownClient)
            } else if clientLabel != nil || canImportAnotherClient {
                options.append(.clientChoice)
            }
            options.append(.whatMailAsksFor)
            return options
        case .checking, .signingIn, .signedIn, .remotePreparing, .remotePaste, .remoteCompleting:
            return []
        }
    }

    public func useSpecificAccount() {
        guard phase == .ready else { return }
        showsAccountField = true
    }

    public func openClientGuide() {
        guard phase == .needsClient || phase == .ready else { return }
        showsClientGuide = true
    }

    public func closeClientGuide() {
        showsClientGuide = false
    }

    public var offersOwnClient: Bool {
        guard phase == .ready, notice == nil else { return false }
        if case .configured(let source) = clientStatus { return source != .environment }
        return false
    }

    isolated deinit {
        signInTask?.cancel()
        remoteTask?.cancel()
        expiryTask?.cancel()
        if remoteURL != nil || phase == .remotePreparing {
            let accounts = self.accounts
            Task { await accounts.cancelRemoteSignIn() }
        }
    }

    public var clientLacksSecret: Bool {
        if case .configuredWithoutSecret = clientStatus { return true }
        return false
    }

    public var canImportClient: Bool {
        if case .configuredWithoutSecret(source: .environment) = clientStatus { return false }
        return (phase == .needsClient || phase == .ready) && (clientStatus == .missing || clientLacksSecret)
    }

    public var canSignIn: Bool { phase == .ready && !clientLacksSecret }

    public var selectedClient: OAuthClientSummary? {
        clients.first(where: \.isSelected) ?? clients.first(where: \.isDefault)
    }

    public var clientLabel: String? { selectedClient.map { "Google client \($0.title)" } }

    public var showsClientPicker: Bool { clients.count > 1 }

    public var canImportAnotherClient: Bool { phase == .ready && !canImportClient }

    public func selectClient(_ id: OAuthClientSummary.ID) async {
        guard phase == .ready || phase == .needsClient else { return }
        errorMessage = nil
        do { try await accounts.selectOAuthClient(id) } catch { errorMessage = Self.message(error) }
        await reloadClients()
    }

    private func reloadClients() async {
        clients = await accounts.oauthClients()
        syncsThroughICloudKeychain = await accounts.signInsSyncThroughICloudKeychain()
    }

    public func copyRemoteAddress() {
        guard let url = remoteURL, let pasteboard else { return }
        pasteboard.copy(url.absoluteString)
        remoteAddressCopied = true
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.remoteAddressCopied = false
        }
    }

    public var clientWarning: String? {
        guard case .configuredWithoutSecret(let source) = clientStatus else { return nil }
        if source == .environment {
            return "The client file set for this development build has no secret. Use the full file, or quit and open "
                + "Mail without it."
        }
        return "This client file is missing its secret, so Google will refuse the sign-in. Import the full file from "
            + "Google Cloud Console."
    }

    public var clientFixHint: String {
        "Download the Desktop client JSON from Google Cloud Console (APIs & Services, Credentials), which includes "
            + "the secret, and import it here."
    }

    public func run() async {
        for await status in accounts.oauthClientStatus() {
            guard !Task.isCancelled else { return }
            clientStatus = status
            await reloadClients()
            switch phase {
            case .checking, .needsClient, .ready:
                phase = status == .missing ? .needsClient : .ready
            case .signingIn, .signedIn, .remotePreparing, .remotePaste, .remoteCompleting:
                break
            }
        }
    }

    public func signIn() {
        guard canSignIn else { return }
        phase = .signingIn
        errorMessage = nil
        let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts = self.accounts
        signInTask = Task { [weak self] in
            do {
                let id = try await accounts.addAccount(loginHint: hint.isEmpty ? nil : hint)
                self?.finish(id)
            } catch {
                self?.fail(error)
            }
        }
    }

    public func cancel() {
        signInTask?.cancel()
        signInTask = nil
        if phase == .signingIn { phase = clientStatus == .missing ? .needsClient : .ready }
    }

    public var canSignInFromAnotherDevice: Bool { canSignIn }

    public func beginRemote() {
        guard canSignIn else { return }
        phase = .remotePreparing
        errorMessage = nil
        pastedAddress = ""
        let hint = loginHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts = self.accounts
        remoteTask = Task { [weak self] in
            do {
                let challenge = try await accounts.beginRemoteSignIn(loginHint: hint.isEmpty ? nil : hint)
                self?.remoteReady(challenge)
            } catch {
                self?.remoteFailed(error)
            }
        }
    }

    public func submitPasted() {
        guard phase == .remotePaste else { return }
        let text = pastedAddress
        pastedAddress = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Paste the address from the browser's address bar first."
            return
        }
        phase = .remoteCompleting
        errorMessage = nil
        let accounts = self.accounts
        remoteTask = Task { [weak self] in
            do {
                let id = try await accounts.completeRemoteSignIn(pasted: text)
                self?.remoteDone(id)
            } catch {
                self?.remoteFailed(error)
            }
        }
    }

    public func cancelRemote() {
        guard phase == .remotePreparing || phase == .remotePaste || phase == .remoteCompleting else { return }
        endRemote(message: nil)
        let accounts = self.accounts
        Task { await accounts.cancelRemoteSignIn() }
    }

    private func remoteReady(_ challenge: RemoteSignInChallenge) {
        remoteTask = nil
        guard phase == .remotePreparing else { return }
        remoteURL = challenge.url
        phase = .remotePaste
        let timeout = remoteTimeout
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.remoteExpired()
        }
    }

    private func remoteExpired() {
        guard phase == .remotePaste else { return }
        endRemote(message: "That sign-in link expired. Start again.")
        let accounts = self.accounts
        Task { await accounts.cancelRemoteSignIn() }
    }

    private func remoteDone(_ id: AccountID) {
        remoteTask = nil
        guard phase == .remoteCompleting else { return }
        endRemote(message: nil)
        finish(id)
    }

    private func remoteFailed(_ error: Error) {
        remoteTask = nil
        guard phase == .remotePreparing || phase == .remoteCompleting else { return }
        if let setup = error as? AccountSetupError, setup.kind == .invalidPaste, remoteURL != nil {
            phase = .remotePaste
            errorMessage = setup.message
        } else if error is CancellationError {
            endRemote(message: nil)
        } else {
            endRemote(message: Self.message(error))
        }
    }

    private func endRemote(message: String?) {
        remoteTask?.cancel()
        remoteTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        remoteURL = nil
        remoteAddressCopied = false
        copiedTask?.cancel()
        pastedAddress = ""
        errorMessage = message
        phase = clientStatus == .missing ? .needsClient : .ready
    }

    public func importClient(json: Data) async {
        errorMessage = nil
        clientNote = nil
        do {
            try await accounts.importOAuthClient(json: json)
            showsClientGuide = false
            clientNote = await accounts.oauthClientImportNote()
        } catch {
            errorMessage = Self.message(error)
        }
        await reloadClients()
    }

    public func importFailed() {
        errorMessage = "That file couldn't be read."
    }

    private func finish(_ id: AccountID) {
        signInTask = nil
        phase = .signedIn(id)
        onSignedIn?(id)
    }

    private func fail(_ error: Error) {
        signInTask = nil
        guard phase == .signingIn else { return }
        phase = clientStatus == .missing ? .needsClient : .ready
        if let setup = error as? AccountSetupError, setup.kind == .cancelled {
            errorMessage = setup.message
        } else if error is CancellationError {
            errorMessage = nil
        } else {
            errorMessage = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        if let setup = error as? AccountSetupError { return setup.message }
        return "Sign-in failed. Try again."
    }
}
