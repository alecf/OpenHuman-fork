import Crypto
import Foundation
import OpenHumanCore
import Synchronization

// Why: a struct, not an enum, so a build that meets a source it does not know still reads the whole record
public struct CredentialSource: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let shared = CredentialSource(rawValue: "shared")
    public static let paired = CredentialSource(rawValue: "paired")
    public static let macMinted = CredentialSource(rawValue: "macMinted")
    public static let ownClient = CredentialSource(rawValue: "ownClient")
    public static let manualDesktop = CredentialSource(rawValue: "manualDesktop")

    public static let rungOrder: [CredentialSource] = [.shared, .paired, .macMinted, .ownClient, .manualDesktop]
}

public enum CredentialStep: String, Sendable, Codable, CaseIterable {
    case entitlement
    case groupMove
    case shareSignIn
    case shareClient
    case readSignIn
    case readClient
    case refresh
    case writeBack
    case scopeCheck

    var category: Log.Category {
        switch self {
        case .refresh, .scopeCheck: .oauth
        default: .keychain
        }
    }
}

public enum CredentialOutcome: Sendable, Equatable, Codable {
    case ok
    case noItem
    case noEntitlement
    case clientMissing
    case googleRefused(code: String)
    case refusedHere
    case broaderGrant
    case keychain(status: Int32)
    case unreadable
    case unreachable
    case keptLocal
    case removedElsewhere

    public static let keychainRefusals: Set<Int32> = [-128, -25293, -25308, -25315]

    public var isKeychainRefusal: Bool {
        if case .keychain(let status) = self { return Self.keychainRefusals.contains(status) }
        return false
    }

    public static func keychainRefusal(in error: any Error) -> CredentialOutcome? {
        let status: Int32
        switch error {
        case TokenStoreError.keychain(let code): status = code
        case OAuthClientStoreError.keychain(let code): status = code
        default: return nil
        }
        let outcome = CredentialOutcome.keychain(status: status)
        return outcome.isKeychainRefusal ? outcome : nil
    }

    public var summary: String {
        switch self {
        case .ok: "ok"
        case .noItem: "no item"
        case .noEntitlement: "no entitlement"
        case .clientMissing: "client missing"
        case .googleRefused(let code): "Google refused (\(code))"
        case .refusedHere: "refused on this device before"
        case .broaderGrant: "broader grant refused"
        case .keychain(let status): "Keychain OSStatus \(status)"
        case .unreadable: "unreadable"
        case .unreachable: "token endpoint unreachable"
        case .keptLocal: "kept on this device"
        case .removedElsewhere: "removed on another device"
        }
    }
}

public struct CredentialEvent: Sendable, Equatable, Codable {
    public var step: CredentialStep
    public var outcome: CredentialOutcome
    public var subject: String?
    public var at: Date
    public var count: Int

    public init(step: CredentialStep, outcome: CredentialOutcome, subject: String?, at: Date, count: Int = 1) {
        self.step = step
        self.outcome = outcome
        self.subject = subject
        self.at = at
        self.count = count
    }

    public var line: String {
        var text = "\(step.rawValue): \(outcome.summary)"
        if let subject { text += " [\(subject)]" }
        if count > 1 { text += " x\(count)" }
        return text
    }
}

// Why: kept on this device only and never holds a token, an address or a secret, so a Diagnostics page can show it
public final class CredentialChainLog: Sendable {
    public static let shared = CredentialChainLog()

    public let capacity: Int
    private let clock: any OHClock
    private let entries = Mutex<[CredentialEvent]>([])

    public init(clock: any OHClock = SystemClock(), capacity: Int = 200) {
        self.clock = clock
        self.capacity = max(1, capacity)
    }

    public func record(_ step: CredentialStep, _ outcome: CredentialOutcome, subject: String? = nil) {
        let outcome = Self.sanitized(outcome)
        let subject = subject.flatMap(Self.safeSubject)
        let now = clock.now
        let limit = capacity
        let added: CredentialEvent? = entries.withLock { list in
            if var last = list.last, last.step == step, last.outcome == outcome, last.subject == subject {
                last.count += 1
                last.at = now
                list[list.count - 1] = last
                return nil
            }
            let event = CredentialEvent(step: step, outcome: outcome, subject: subject, at: now)
            list.append(event)
            if list.count > limit { list.removeFirst(list.count - limit) }
            return event
        }
        guard let added else { return }
        if added.outcome == .ok {
            Log(step.category).info("credential " + added.line)
        } else {
            Log(step.category).notice("credential " + added.line)
        }
    }

    public func events() -> [CredentialEvent] { entries.withLock { $0 } }

    public func latest(_ step: CredentialStep, subject: String? = nil) -> CredentialEvent? {
        entries.withLock { list in list.last { $0.step == step && (subject == nil || $0.subject == subject) } }
    }

    public func clear() { entries.withLock { $0.removeAll() } }

    public static func subject(account email: String) -> String {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(("openhuman.credential-log.v1:" + key).utf8))
        return "account-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    public static func subject(client clientID: String) -> String {
        subject(clientKey: OAuthClientConfig.registryKey(clientID: clientID))
    }

    public static func subject(clientKey: String) -> String { "client-" + String(clientKey.prefix(8)) }

    public static func safeCode(_ raw: String) -> String {
        let ok = !raw.isEmpty && raw.count <= 64
            && raw.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
        return ok ? raw : "other"
    }

    static func safeSubject(_ raw: String) -> String? {
        let ok = !raw.isEmpty && raw.count <= 40
            && raw.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
        return ok ? raw : nil
    }

    static func sanitized(_ outcome: CredentialOutcome) -> CredentialOutcome {
        if case .googleRefused(let code) = outcome { return .googleRefused(code: safeCode(code)) }
        return outcome
    }
}
