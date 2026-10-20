import Foundation

public enum AIAvailability: Sendable, Hashable {
    case available
    case unavailable(reason: UnavailableReason)

    public var isAvailable: Bool { self == .available }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    public enum UnavailableReason: Sendable, Hashable {
        case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, requiresNewerOS
        case entitlementMissing, usageLimitReached
        case modelNotDownloaded(sizeBytes: Int64), downloading(progress: Double)
        case binaryNotFound(name: String), notLoggedIn(name: String), unsupportedVersion(found: String, minimum: String)
        case localeNotSupported
        case notConsented
        case onDeviceOnly
        case disabledBySettings
        case other(String)
    }
}
