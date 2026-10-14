import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class PrivacySettingsModel {
    public private(set) var accounts: [Account] = []
    public var account: AccountID? {
        didSet { if account != oldValue { accountChanged() } }
    }
    public private(set) var policy: StoredSetting<RemoteImagePolicy>?
    public private(set) var senders: StoredSetting<[String]>?
    public var newSender = ""
    public private(set) var errorMessage: String?
    public let availability: SettingsAvailability

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(data: any MailDataSource, settings: (any SettingsPort)?, availability: SettingsAvailability) {
        self.data = data
        self.settings = settings
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, settings: environment.settings,
                  availability: SettingsAvailability(environment: environment))
    }

    isolated deinit {
        task?.cancel()
    }

    public func start() {
        guard task == nil else { return }
        let data = self.data
        task = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    self.accounts = list
                    if self.account == nil || !list.contains(where: { $0.id == self.account }) { self.account = list.first?.id }
                }
            } catch {}
        }
    }

    private func accountChanged() {
        policy?.stop()
        senders?.stop()
        policy = nil
        senders = nil
        guard let account else { return }
        let policy = StoredSetting(AppSettings.remoteImages(account), port: settings)
        let senders = StoredSetting(AppSettings.remoteImageSenders(account), port: settings)
        policy.start()
        senders.start()
        self.policy = policy
        self.senders = senders
    }

    public static func title(_ policy: RemoteImagePolicy) -> String {
        switch policy {
        case .block: "Block remote images"
        case .ask: "Ask before loading"
        case .allow: "Load remote images"
        }
    }

    public static let blockNote = "Remote images can tell a sender when and where you opened a message. Blocked is the safe default."

    public func setPolicy(_ value: RemoteImagePolicy) async { await policy?.set(value) }

    public static func normalizedSender(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix("@") { return trimmed.dropFirst().contains(".") ? trimmed : nil }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count == 1 { return trimmed.contains(".") ? "@" + trimmed : nil }
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") ? trimmed : nil
    }

    public func addSender() async {
        guard let senders else { return }
        guard let value = Self.normalizedSender(newSender) else {
            errorMessage = "Enter an address like name@example.com or a domain like @example.com."
            return
        }
        errorMessage = nil
        newSender = ""
        guard !senders.value.contains(value) else { return }
        await senders.set((senders.value + [value]).sorted())
    }

    public func removeSender(_ value: String) async {
        guard let senders else { return }
        await senders.set(senders.value.filter { $0 != value })
    }
}
