import Foundation
import OpenHumanAI

public protocol MachineConditions: Sendable {
    var isLowPowerModeEnabled: Bool { get }
    var thermalState: ProcessInfo.ThermalState { get }
    var physicalMemoryBytes: UInt64 { get }
}

public struct SystemMachineConditions: MachineConditions {
    public init() {}
    public var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    public var thermalState: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    public var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
}

public struct LocalClassifierGate: Sendable {
    public static let minimumMemoryBytes: UInt64 = 8 * 1_073_741_824

    public let conditions: any MachineConditions
    public let allowsLowPowerMode: @Sendable () -> Bool

    public init(conditions: any MachineConditions = SystemMachineConditions(),
                allowsLowPowerMode: @escaping @Sendable () -> Bool = { false }) {
        self.conditions = conditions
        self.allowsLowPowerMode = allowsLowPowerMode
    }

    public static let lowPowerReason = "Paused in Low Power Mode. You can allow it in Settings › AI › Classifier."
    public static let heatReason = "Paused while this Mac is hot."
    public static let memoryReason = "Needs a Mac with at least 8 GB of memory."

    public func blockingReason() -> String? {
        if conditions.physicalMemoryBytes < Self.minimumMemoryBytes { return Self.memoryReason }
        switch conditions.thermalState {
        case .serious, .critical: return Self.heatReason
        default: break
        }
        if conditions.isLowPowerModeEnabled && !allowsLowPowerMode() { return Self.lowPowerReason }
        return nil
    }

    public var availability: AIAvailability {
        blockingReason().map { .unavailable(reason: .other($0)) } ?? .available
    }
}
