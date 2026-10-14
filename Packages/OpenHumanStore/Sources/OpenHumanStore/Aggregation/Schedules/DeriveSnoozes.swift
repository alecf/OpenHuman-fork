import Foundation
import OpenHumanCore

enum ScheduleDerivation {}

extension ScheduleDerivation {
    struct MessageLabels: Equatable {
        var visible: Bool
        var names: [String]
    }

    struct Snooze: Equatable {
        enum Status: String { case active, malformed }
        var status: Status
        var wakeAt: Int64?
        var labelName: String?
        var stampLabelCount: Int
    }

    static func deriveSnoozes(_ messages: [MessageLabels]) throws -> Snooze? {
        var stamps: [String: ScheduleLabel] = [:]
        var marked = false
        for message in messages where message.visible {
            for name in message.names {
                switch ScheduleLabel.parse(name) {
                case let .schedule(label) where label.kind == .snoozed:
                    stamps[name] = label
                case .marker(.snoozed), .malformed(.snoozed):
                    marked = true
                default:
                    break
                }
            }
        }
        if let earliest = stamps.values.min() {
            return Snooze(status: .active, wakeAt: Int64((earliest.due.timeIntervalSince1970 * 1000).rounded()),
                          labelName: earliest.name, stampLabelCount: stamps.count)
        }
        return marked ? Snooze(status: .malformed, wakeAt: nil, labelName: nil, stampLabelCount: 0) : nil
    }
}
