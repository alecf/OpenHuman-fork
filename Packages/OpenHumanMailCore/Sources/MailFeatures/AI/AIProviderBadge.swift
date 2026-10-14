import Foundation
import OpenHumanAI

public struct AIProviderBadge: Hashable, Sendable {
    public let title: String
    public let symbol: String
    public let leavesMac: Bool
    public let help: String
    public let short: String

    public init(title: String, symbol: String, leavesMac: Bool, help: String, short: String) {
        self.title = title
        self.symbol = symbol
        self.leavesMac = leavesMac
        self.help = help
        self.short = short
    }

    public init(provenance: AIProvenance) {
        self.init(providerName: provenance.providerName, location: provenance.dataLocation, fromCache: provenance.fromCache)
    }

    public init(providerName: String, location: AIDataLocation, fromCache: Bool = false) {
        let again = fromCache ? String(localized: " (saved earlier)") : ""
        switch location {
        case .onDevice:
            self.init(title: String(localized: "On this Mac"), symbol: "desktopcomputer", leavesMac: false,
                      help: String(localized: "Generated on this Mac (\(providerName))") + again,
                      short: String(localized: "On this Mac"))
        case .appleCloud:
            self.init(title: String(localized: "Sent to Apple Private Cloud Compute"), symbol: "cloud", leavesMac: true,
                      help: String(localized: "Generated on Apple's servers (Private Cloud Compute), not on this Mac") + again,
                      short: String(localized: "Private Cloud Compute · leaves this Mac"))
        case .thirdParty(let vendor):
            self.init(title: String(localized: "Sent to \(vendor) via \(providerName)"), symbol: "arrow.up.right",
                      leavesMac: true,
                      help: String(localized: "The email text was sent to \(vendor) through your \(providerName) login") + again,
                      short: String(localized: "\(providerName) · leaves this Mac"))
        }
    }
}

public enum AIWording {
    public static func reason(_ reason: AIAvailability.UnavailableReason, providerName: String? = nil) -> String {
        let name = providerName ?? String(localized: "The AI provider")
        switch reason {
        case .deviceNotEligible:
            return String(localized: "This Mac can't run Apple's on-device model")
        case .appleIntelligenceNotEnabled:
            return String(localized: "Turn on Apple Intelligence in System Settings")
        case .modelNotReady:
            return String(localized: "Apple's on-device model is still getting ready. Try again in a few minutes")
        case .entitlementMissing:
            return String(localized: "Not available in this version of Mail")
        case .usageLimitReached:
            return String(localized: "Private Cloud Compute limit reached; try later")
        case .modelNotDownloaded(let size):
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return String(localized: "Download the local model (\(formatted)) in Settings › AI")
        case .downloading(let progress):
            return String(localized: "The local model is downloading (\(Int((progress * 100).rounded())) %)")
        case .binaryNotFound(let binary):
            return binary == "claude" ? String(localized: "Install Claude Code")
                                      : String(localized: "Install \(binary)")
        case .notLoggedIn(let binary):
            return String(localized: "Run `\(binary) auth login` in Terminal")
        case .unsupportedVersion(let found, let minimum):
            return String(localized: "\(name) \(found) is too old; update to \(minimum) or later")
        case .localeNotSupported:
            return String(localized: "The model doesn't support this language")
        case .notConsented:
            return String(localized: "\(name) needs your OK before any email text is sent to it")
        case .onDeviceOnly:
            return String(localized: "This account uses on-device AI only, and no on-device model is ready")
        case .disabledBySettings:
            return String(localized: "Turned off in Settings › AI")
        case .other(let text):
            return text
        }
    }

    public static func failure(_ error: any Error, providerName: String? = nil) -> String {
        guard let error = error as? AIError else { return String(localized: "Something went wrong") }
        switch error {
        case .unavailable(let reason):
            return Self.reason(reason, providerName: providerName)
        case .contextOverflow:
            return String(localized: "Too long for this model. Select less and try again")
        case .invalidOutput:
            return String(localized: "The model's answer wasn't usable")
        case .refused:
            return String(localized: "The model's safety filter stopped this text. Try a smaller part or other words")
        case .timeout:
            return String(localized: "The model took too long")
        case .cancelled:
            return String(localized: "Stopped")
        case .providerFailed:
            return String(localized: "\(providerName ?? String(localized: "The AI provider")) failed")
        case .outputBlocked:
            return String(localized: "Hidden: the answer looked like it contained a password or key")
        }
    }

    public static let suspicious = String(localized: "This email may contain instructions aimed at AI tools. Check the text before you use it.")
}
