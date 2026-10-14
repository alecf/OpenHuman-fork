import Foundation
import OpenHumanCore

extension ScheduleDerivation {
    struct DraftSchedule: Equatable {
        var state: DraftState
        var sendAt: Int64?
        var lastError: String?
    }

    struct DraftScheduleInput: Equatable {
        var isDirty: Bool
        var current: DraftSchedule
        var header: String?
        var labelNames: [String]
        var remoteChanged: Bool = false
    }

    static let unreadableScheduleError = "scheduled time unreadable"

    // The header wins over labels; a label alone never schedules
    static func deriveScheduledSend(_ input: DraftScheduleInput) throws -> DraftSchedule {
        let current = input.current
        if input.isDirty { return current }
        switch current.state {
        case .sending, .sent, .discarded: return current
        case .failed where !input.remoteChanged && current.lastError != unreadableScheduleError: return current
        case .editing, .scheduled, .failed: break
        }
        let clearedError = current.lastError == unreadableScheduleError ? nil : current.lastError
        let unreadable = DraftSchedule(state: .failed, sendAt: nil, lastError: unreadableScheduleError)
        if let header = input.header?.trimmingCharacters(in: .whitespaces) {
            guard let due = ScheduleStamp.parse(header) else { return unreadable }
            return DraftSchedule(state: .scheduled, sendAt: Int64((due.timeIntervalSince1970 * 1000).rounded()),
                                 lastError: current.state == .failed ? nil : clearedError)
        }
        let malformedLabel = input.labelNames.contains { ScheduleLabel.parse($0) == .malformed(.scheduled) }
        if malformedLabel { return unreadable }
        switch current.state {
        case .scheduled, .failed:
            return DraftSchedule(state: .editing, sendAt: nil, lastError: current.state == .failed ? nil : clearedError)
        default:
            return current
        }
    }
}
