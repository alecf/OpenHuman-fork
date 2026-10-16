import Foundation
import Observation

@MainActor @Observable
public final class DeveloperOptions {
    public static let enabledKey = "developerOptions.enabled"
    public static let sendToDeviceKey = "developerOptions.sendToDevice"
    public static let debuggingToolsKey = "developerOptions.debuggingTools"

    public let isAvailable: Bool
    public var isOn: Bool {
        didSet { if isAvailable { defaults.set(isOn, forKey: Self.enabledKey) } }
    }
    public var sendToDevice: Bool {
        didSet { if isAvailable { defaults.set(sendToDevice, forKey: Self.sendToDeviceKey) } }
    }
    public var debuggingTools: Bool {
        didSet { if isAvailable { defaults.set(debuggingTools, forKey: Self.debuggingToolsKey) } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(devFeedback: DevFeedbackAvailability, defaults: UserDefaults) {
        self.defaults = defaults
        isAvailable = devFeedback.isAvailable
        isOn = isAvailable && defaults.object(forKey: Self.enabledKey) as? Bool == true
        sendToDevice = isAvailable && defaults.object(forKey: Self.sendToDeviceKey) as? Bool == true
        debuggingTools = isAvailable && defaults.object(forKey: Self.debuggingToolsKey) as? Bool == true
    }

    public var showsDeveloperItems: Bool { isAvailable && isOn }
    public var offersSendToDevice: Bool { isAvailable && sendToDevice }
    public var showsDebuggingTools: Bool { isAvailable && debuggingTools }
}
