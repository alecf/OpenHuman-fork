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
    public let requiredMemoryBytes: UInt64
    public let allowsLowPowerMode: @Sendable () -> Bool

    public init(conditions: any MachineConditions = SystemMachineConditions(),
                requiredMemoryBytes: UInt64 = LocalClassifierGate.minimumMemoryBytes,
                allowsLowPowerMode: @escaping @Sendable () -> Bool = { false }) {
        self.conditions = conditions
        self.requiredMemoryBytes = requiredMemoryBytes
        self.allowsLowPowerMode = allowsLowPowerMode
    }

    public static let lowPowerReason =
        "Paused in Low Power Mode. You can allow it in Settings › AI › High-accuracy model."
    public static let heatReason = "Paused while this Mac is hot."
    public static let memoryReason = needsMemoryText(minimumMemoryBytes)

    public static func needsMemoryText(_ bytes: UInt64) -> String {
        "Needs a Mac with at least \(bytes / 1_073_741_824) GB of memory."
    }

    public var memoryShortfall: String? {
        conditions.physicalMemoryBytes < requiredMemoryBytes ? Self.needsMemoryText(requiredMemoryBytes) : nil
    }

    public func blockingReason() -> String? {
        if let memoryShortfall { return memoryShortfall }
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
