import Foundation

// Why: Mail reaches Apple's on-device model through FoundationModels APIs that are new in macOS 27; earlier systems run Mail without it
public struct AppleModelSupport: Sendable, Hashable {
    public var isSupported: Bool

    public init(isSupported: Bool) { self.isSupported = isSupported }

    public static let supported = AppleModelSupport(isSupported: true)
    public static let unsupported = AppleModelSupport(isSupported: false)

    public static var current: AppleModelSupport {
        if #available(macOS 27, iOS 27, *) { return .supported }
        return .unsupported
    }

    public var unavailableReason: AIAvailability.UnavailableReason? { isSupported ? nil : .requiresNewerOS }
}
