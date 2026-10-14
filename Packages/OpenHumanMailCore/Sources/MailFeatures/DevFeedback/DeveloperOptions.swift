import Foundation
import Observation

@MainActor @Observable
public final class DeveloperOptions {
    public static let environmentKey = "OPENHUMAN_DEVELOPER"
    public static let enabledKey = "developerOptions.enabled"

    public let isAvailable: Bool
    public var isOn: Bool {
        didSet { if isAvailable { defaults.set(isOn, forKey: Self.enabledKey) } }
    }

    public static let sendToDeviceKey = "developerOptions.sendToDevice"
    public var sendToDevice: Bool {
        didSet { if isAvailable { defaults.set(sendToDevice, forKey: Self.sendToDeviceKey) } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(environment: [String: String], devFeedback: DevFeedbackAvailability, defaults: UserDefaults) {
        self.defaults = defaults
        let requested = environment[Self.environmentKey]?.trimmingCharacters(in: .whitespaces) == "1"
        isAvailable = requested || devFeedback.isAvailable
        isOn = isAvailable && (requested || defaults.object(forKey: Self.enabledKey) as? Bool == true)
        sendToDevice = isAvailable && defaults.object(forKey: Self.sendToDeviceKey) as? Bool == true
    }

    public var showsDeveloperItems: Bool { isAvailable && isOn }
    public var offersSendToDevice: Bool { isAvailable && sendToDevice }
}
